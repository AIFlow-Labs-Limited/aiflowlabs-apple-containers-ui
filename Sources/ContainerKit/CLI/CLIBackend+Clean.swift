import Foundation

// MARK: - `container clean` (Apple container 1.7+)

// What the command does, as seen on 1.7.1: for each **running** container it trims the root filesystem and every
// named volume mounted in it, so blocks freed inside the guest are given back to the Mac. Files are not touched.
// It prints the id of each container it cleaned and takes about a second. A stopped container fails with
// `container is not running`, an unknown one with `container with ID … not found`; with several ids the others
// are still cleaned and the command exits 1.
extension CLIBackend {
    /// `container clean --help` exits 0 only on runtimes that have the command (1.7+); older ones treat `clean`
    /// as a missing plugin. The answer is cached; a failure to run the probe is not.
    public func supportsClean() async -> Bool {
        if let cleanSupport { return cleanSupport }
        guard let result = try? await runRaw(["clean", "--help"], timeout: .seconds(15)) else { return false }
        let supported = result.exitCode == 0
        cleanSupport = supported
        return supported
    }

    /// `container clean -- IDS…`. On a runtime without the command the stream fails with `.unsupported` rather
    /// than the CLI's "unknown command"; a container that is not running is named in plain words.
    public nonisolated func cleanContainers(_ ids: [String]) -> LineStream {
        validatedStream {
            guard !ids.isEmpty else { throw BackendError.other("Choose at least one running container.") }
            try Self.validateOperands(ids, "Container")
            let stream = streamCommand(Self.cleanArguments(ids))
            return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(ProcessRunner.streamBufferLimit)) {
                continuation in
                let task = Task {
                    do {
                        for try await line in stream { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: Self.cleanFailure(error))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    /// Turns "unknown command 'clean'" into `.unsupported` and the CLI's `internalError: "failed to clean
    /// container" (cause: "invalidState: "container is not running"")` into a sentence. Other errors are returned
    /// unchanged.
    static func cleanFailure(_ error: any Error) -> any Error {
        guard case BackendError.commandFailed(let command, let exitCode, let message) = error else { return error }
        if message.localizedCaseInsensitiveContains("unknown command") {
            return BackendError.unsupported(
                feature: "Reclaim Disk Space",
                reason: "this `container` CLI has no `clean` command. It was added in Apple container 1.7.")
        }
        if message.localizedCaseInsensitiveContains("is not running") {
            return BackendError.commandFailed(
                command: command, exitCode: exitCode,
                message: "Disk space can only be reclaimed from a running container. Start it and try again. "
                    + "(\(message))")
        }
        return error
    }

    /// argv after the executable for `cleanContainers`.
    static func cleanArguments(_ ids: [String]) -> [String] {
        ["clean", "--"] + ids
    }

    /// `container clean -- IDS…` as a shell-quoted line, shown before the command's output in the Activity window.
    public static func cleanCommandPreview(_ ids: [String]) -> String {
        ShellQuote.join(["container"] + cleanArguments(ids))
    }
}
