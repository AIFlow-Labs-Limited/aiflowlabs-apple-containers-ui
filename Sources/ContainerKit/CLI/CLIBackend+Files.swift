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

    /// `container copy -- ID:PATH STAGING`, then moves the result to `localPath`.
    ///
    /// The CLI appends the source name when the destination is an existing directory and cannot address a
    /// local path containing `:`, so the copy goes to a fresh staging directory first and is then moved into
    /// place (replacing an existing item only after the copy succeeded).
    public func copyOut(_ id: String, path: String, to localPath: String) async throws {
        try Self.validateOperand(id, "Container")
        let source = try Self.copyReference(id, path)
        let stage = try Self.makeStagingDirectory()
        defer { try? FileManager.default.removeItem(at: stage) }
        let staged = stage.appending(path: "payload")
        let arguments = ["copy", "--", source, staged.path(percentEncoded: false)]
        try await execute(arguments, timeout: nil)
        let files = FileManager.default
        guard files.fileExists(atPath: staged.path(percentEncoded: false)) else {
            throw BackendError.commandFailed(
                command: display(arguments), exitCode: 0, message: "The copy finished but produced no file.")
        }
        let destination = URL(filePath: localPath)
        do {
            if files.fileExists(atPath: destination.path(percentEncoded: false)) {
                _ = try files.replaceItemAt(destination, withItemAt: staged)
            } else {
                try files.moveItem(at: staged, to: destination)
            }
        } catch {
            throw BackendError.commandFailed(
                command: display(arguments), exitCode: 0,
                message: "Copied, but could not move the result to \(localPath): \(error.localizedDescription)")
        }
    }

    /// `container copy -- LOCALPATH ID:PATH`. A local path containing `:` (which the CLI would read as a
    /// container reference) is copied through a staging directory.
    public func copyIn(_ id: String, localPath: String, to path: String) async throws {
        try Self.validateOperand(id, "Container")
        let destination = try Self.copyReference(id, path)
        guard FileManager.default.fileExists(atPath: localPath) else {
            throw BackendError.other("“\(localPath)” does not exist.")
        }
        var source = URL(filePath: localPath).standardizedFileURL.path(percentEncoded: false)
        while source.count > 1, source.hasSuffix("/") { source.removeLast() }
        var stage: URL?
        defer { if let stage { try? FileManager.default.removeItem(at: stage) } }
        if source.contains(":") {
            let directory = try Self.makeStagingDirectory()
            stage = directory
            let staged = directory.appending(path: "payload")
            do { try FileManager.default.copyItem(at: URL(filePath: source), to: staged) } catch {
                throw BackendError.other("Could not prepare “\(localPath)” for copying: \(error.localizedDescription)")
            }
            source = staged.path(percentEncoded: false)
        }
        try await execute(["copy", "--", source, destination], timeout: nil)
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

    /// `container commit -- ID REFERENCE`.
    public nonisolated func commitContainer(_ id: String, reference: String) -> LineStream {
        validatedStream {
            try Self.validateOperand(id, "Container")
            try Self.validateOperand(reference, "Image reference")
            guard !reference.isEmpty else { throw BackendError.other("Enter a name for the new image.") }
            return streamCommand(Self.commitArguments(id, reference: reference))
        }
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

    /// `ID:PATH` for `container copy`, which splits its operands on `:` and so cannot address a container path
    /// (or id) that contains one.
    static func copyReference(_ id: String, _ path: String) throws -> String {
        let path = try validatedContainerPath(path)
        guard !path.contains(":"), !id.contains(":") else {
            throw BackendError.unsupported(
                feature: "Copying “\(path)”",
                reason: "`container cp` cannot address paths that contain a colon. Rename it first.")
        }
        return "\(id):\(path)"
    }

    /// A new empty directory under the user's temporary directory.
    static func makeStagingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "ContainerDesktop-cp-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw BackendError.other("Could not create a temporary folder: \(error.localizedDescription)")
        }
        return url
    }

    /// Runs `container exec -- ID COMMAND…` and returns the raw result (binary-safe stdout). Only CLI-level
    /// failures throw: the system is down, or the container does not exist.
    func execRaw(_ id: String, _ command: [String], timeout: Duration?) async throws -> ProcessResult {
        try Self.validateOperand(id, "Container")
        let arguments = Self.execArguments(id, command)
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
