import ContainerKit
import Foundation

// `container clean` as the mock plays it: the same output and the same refusals as container 1.7.1 (the id of
// each cleaned container; "not running" for a stopped one; "not found" for an unknown one, after the others
// were cleaned).
extension MockBackend {
    public func supportsClean() async -> Bool { cleanSupported }

    /// Makes the mock play a runtime with or without `container clean` (tests, previews).
    public func setCleanSupported(_ supported: Bool) { cleanSupported = supported }

    public nonisolated func cleanContainers(_ ids: [String]) -> LineStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var failure: BackendError?
                    for id in ids {
                        try Task.checkCancellation()
                        do {
                            try await self.clean(id)
                            continuation.yield(OutputLine(id))
                        } catch let error as BackendError {
                            if case .unsupported = error { throw error }
                            if error == .systemNotRunning { throw error }
                            failure = failure ?? error
                        }
                        try await Task.sleep(for: .milliseconds(120))
                    }
                    if let failure { throw failure }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is CancellationError ? BackendError.cancelled : error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func clean(_ id: String) throws {
        if !systemRunning { throw BackendError.systemNotRunning }
        guard cleanSupported else {
            throw BackendError.unsupported(
                feature: "Reclaim Disk Space", reason: "container clean requires Apple container 1.7 or later.")
        }
        guard let container = containers.first(where: { $0.id == id }) else {
            throw BackendError.notFound(kind: "container", id: id)
        }
        guard container.isRunning else {
            throw BackendError.commandFailed(
                command: "container clean -- \(id)", exitCode: 1,
                message: "Disk space can only be reclaimed from a running container. Start it and try again. "
                    + "(internalError: \"failed to clean container\" (cause: \"invalidState: \"container is not "
                    + "running\"\"))")
        }
        cleanedContainers.append(id)
    }
}
