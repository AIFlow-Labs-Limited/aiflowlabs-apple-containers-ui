import Foundation

// MARK: - ContainerFileOperations

extension CLIBackend {
    /// Timeout for a file preview read (`head -c`).
    static let previewTimeout: Duration = .seconds(30)

    /// `container exec -- ID sh -c SCRIPT sh NONCE PATH LIMIT` (see `FileListing` for the script and why it is
    /// safe for any file name).
    public func listDirectory(_ id: String, path: String, limit: Int) async throws -> ContainerDirectoryListing {
        let path = try Self.validatedContainerPath(path)
        let nonce = FileListing.makeNonce()
        let command = FileListing.command(nonce: nonce, path: path, limit: max(1, limit))
        let result = try await execRaw(id, command, timeout: Self.queryTimeout)
        switch FileListing.interpret(
            exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderrText, nonce: nonce, path: path,
            limit: max(1, limit))
        {
        case .listing(let listing): return listing
        case .failure(let message):
            throw BackendError.commandFailed(
                command: display(Self.execArguments(id, command)), exitCode: result.exitCode, message: message)
        }
    }

    /// `container exec -- ID head -c MAXBYTES -- PATH`.
    public func readFile(_ id: String, path: String, maxBytes: Int) async throws -> Data {
        let path = try Self.validatedContainerPath(path)
        let command = ["head", "-c", String(max(0, maxBytes)), "--", path]
        let result = try await execRaw(id, command, timeout: Self.previewTimeout)
        try checkExec(id, command, result)
        return result.stdout.prefix(max(0, maxBytes))
    }

    /// `container exec -- ID mkdir -- PATH`.
    public func makeDirectory(_ id: String, path: String) async throws {
        let command = ["mkdir", "--", try Self.validatedContainerPath(path)]
        try checkExec(id, command, try await execRaw(id, command, timeout: Self.actionTimeout))
    }

    /// `container exec -- ID mv -- SOURCE DESTINATION`.
    public func moveItem(_ id: String, from source: String, to destination: String) async throws {
        let from = try Self.validatedContainerPath(source)
        let to = try Self.validatedContainerPath(destination)
        guard from != "/", to != "/" else { throw BackendError.other("The root directory cannot be renamed.") }
        let command = ["mv", "--", from, to]
        try checkExec(id, command, try await execRaw(id, command, timeout: Self.actionTimeout))
    }

    /// `container exec -- ID rm -rf -- PATH`, after `ContainerPath.deletionRefusal` has let the path through.
    public func deleteItem(_ id: String, path: String) async throws {
        let path = try Self.validatedContainerPath(path)
        if let refusal = ContainerPath.deletionRefusal(path) { throw BackendError.other(refusal) }
        let command = ["rm", "-rf", "--", path]
        try checkExec(id, command, try await execRaw(id, command, timeout: Self.pruneTimeout))
    }

    /// `container commit --help` exits 0 only on runtimes that have the command (1.6+); older ones treat
    /// `commit` as a missing plugin. The answer is cached; a failure to run the probe is not.
    public func supportsCommit() async -> Bool {
        if let commitSupport { return commitSupport }
        guard let result = try? await runRaw(["commit", "--help"], timeout: .seconds(15)) else { return false }
        let supported = result.exitCode == 0
        commitSupport = supported
        return supported
    }

    /// `container commit -- ID REFERENCE`. On a runtime without the command (before 1.6) the stream fails with
    /// `.unsupported` rather than the CLI's "unknown command … if 'commit' is a plugin, check that it exists…".
    public nonisolated func commitContainer(_ id: String, reference: String) -> LineStream {
        validatedStream {
            try Self.validateOperand(id, "Container")
            try Self.validateOperand(reference, "Image reference")
            guard !reference.isEmpty else { throw BackendError.other("Enter a name for the new image.") }
            let stream = streamCommand(Self.commitArguments(id, reference: reference))
            return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(ProcessRunner.streamBufferLimit)) {
                continuation in
                let task = Task {
                    do {
                        for try await line in stream { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: Self.commitFailure(error))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Turns the CLI's "unknown command 'commit'" into `.unsupported`; any other error is returned unchanged.
    static func commitFailure(_ error: any Error) -> any Error {
        guard case BackendError.commandFailed(_, _, let message) = error,
            message.localizedCaseInsensitiveContains("unknown command")
        else { return error }
        return BackendError.unsupported(
            feature: "Save as Image",
            reason: "this `container` CLI has no `commit` command. It was added in Apple container 1.6.")
    }

    /// argv after the executable for `commitContainer`.
    static func commitArguments(_ id: String, reference: String) -> [String] {
        ["commit", "--", id, reference]
    }

    /// `container commit -- ID REFERENCE` as a shell-quoted line, for the live preview in "Save as Image…".
    public static func commitCommandPreview(_ id: String, reference: String) -> String {
        ShellQuote.join(["container"] + commitArguments(id, reference: reference))
    }

    // MARK: - Helpers

    /// argv after the executable for a non-interactive exec.
    static func execArguments(_ id: String, _ command: [String]) -> [String] {
        ["exec", "--", id] + command
    }

    /// A normalized absolute path, or an error for a relative path or one containing NUL.
    static func validatedContainerPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw BackendError.other("“\(path)” is not an absolute path inside the container.")
        }
        return ContainerPath.normalize(path)
    }

    /// Decodes its arguments with `printf` and runs them as a command: `sh -c SCRIPT sh ENCODED…`. The `.`
    /// keeps a trailing newline in a name from being dropped by the command substitution.
    static let byteExactScript = #"for a do shift; v=$(printf "$a."); set -- "$@" "${v%.}"; done; exec "$@""#

    /// `command`, in a form that reaches the container byte for byte.
    ///
    /// Foundation's `Process` hands arguments to the child in decomposed Unicode form (`é` becomes `e` plus a
    /// combining accent, a Hangul syllable becomes its jamo), so a path that is stored precomposed inside the
    /// container, which is how Linux tools write it, would name a file that does not exist. A command with
    /// such an argument is sent as ASCII `printf` escapes and decoded by `sh` inside the container. Commands
    /// without one are returned unchanged and need no shell.
    static func byteExact(_ command: [String]) -> [String] {
        guard command.contains(where: { !$0.decomposedStringWithCanonicalMapping.utf8.elementsEqual($0.utf8) })
        else { return command }
        return ["sh", "-c", byteExactScript, "sh"] + command.map(printfEscaped)
    }

    /// `text` as an ASCII `printf` format that prints exactly its bytes: non-ASCII bytes and control characters
    /// as octal escapes, `%` and `\` doubled, and a leading `-` escaped so it is not read as an option.
    static func printfEscaped(_ text: String) -> String {
        var result = ""
        for (index, byte) in text.utf8.enumerated() {
            switch byte {
            case UInt8(ascii: "%"): result += "%%"
            case UInt8(ascii: "\\"): result += "\\\\"
            case 0x20...0x7E where !(index == 0 && byte == UInt8(ascii: "-")):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let octal = String(byte, radix: 8)
                result += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
            }
        }
        return result
    }

    /// Runs `container exec -- ID COMMAND…` and returns the raw result (binary-safe stdout). Only CLI-level
    /// failures throw: the system is down, or the container does not exist.
    func execRaw(_ id: String, _ command: [String], timeout: Duration?) async throws -> ProcessResult {
        try Self.validateOperand(id, "Container")
        let arguments = Self.execArguments(id, Self.byteExact(command))
        let result = try await runRaw(arguments, timeout: timeout)
        if result.exitCode != 0 {
            let stderr = result.stderrText
            if Self.indicatesContainerMissing(stderr, id: id) { throw BackendError.notFound(kind: "container", id: id) }
            if CLIErrorMapper.indicatesSystemNotRunning(stderr) { throw BackendError.systemNotRunning }
            if CLIErrorMapper.isPluginsUnavailable(stderr), await failure(arguments, result) == .systemNotRunning {
                throw BackendError.systemNotRunning
            }
        }
        return result
    }

    /// Throws `.commandFailed` (with the exact command) when the exec'd program exited non-zero.
    nonisolated func checkExec(_ id: String, _ command: [String], _ result: ProcessResult) throws {
        guard result.exitCode != 0 else { return }
        let message = CLIErrorMapper.cleanMessage(result.stderrText)
        throw BackendError.commandFailed(
            command: display(Self.execArguments(id, command)), exitCode: result.exitCode,
            message: message.isEmpty ? "`\(command[0])` failed with exit code \(result.exitCode)." : message)
    }
}
