import ContainerKit
import Foundation

/// The waits a compose run performs itself, because the runtime has neither health checks nor exit codes.
///
/// A health check is the service's `healthcheck.test`, run inside the container through the backend's exec:
/// exit code 0 is healthy. Timing follows Compose, with one difference: the first probe runs at once instead of
/// one `interval` after the start, and that first probe does not count towards `retries`, so a container is
/// declared unhealthy no earlier than Docker would declare it.
enum ComposeWait {
    /// Outcome of one probe.
    enum Probe: Equatable, Sendable {
        case passed
        /// The command ran and exited non-zero.
        case failed(exitCode: Int32, output: String)
        /// The command did not finish within the check's `timeout`.
        case timedOut
        /// The command could not be run at all.
        case error(BackendError)

        /// "exit code 1: connection refused" — for the run's output and the final error.
        var summary: String {
            switch self {
            case .passed: return "passed"
            case .failed(let code, let output):
                return output.isEmpty ? "exit code \(code)" : "exit code \(code): \(output)"
            case .timedOut: return "no answer within the timeout"
            case .error(let error): return error.errorDescription ?? "the check could not be run"
            }
        }
    }

    /// How often `untilCompleted` looks at the container.
    static let completionPollInterval: Duration = .seconds(1)

    /// Probes `container` until its health check passes.
    ///
    /// - Parameter report: called before every probe with its number (1-based), for the live status.
    /// - Throws: `BackendError` when the check fails `retries` times in a row after the start period, when the
    ///   container stops or disappears meanwhile, or `CancellationError` when the run is cancelled.
    static func untilHealthy(
        container: String, check: ComposeHealthcheck, backend: any ContainerBackend,
        output: LineStream.Continuation, report: @MainActor (Int) -> Void
    ) async throws {
        let clock = ContinuousClock()
        let began = clock.now
        var attempt = 0
        var failures = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            await report(attempt)
            let result = await probe(container: container, check: check, backend: backend)
            try Task.checkCancellation()
            if result == .passed {
                output.yield(OutputLine("\(container) is healthy (attempt \(attempt))."))
                return
            }
            output.yield(OutputLine("Health check attempt \(attempt) on \(container): \(result.summary)"))
            try await requireRunning(container, backend: backend, whileWaitingFor: "it became healthy")
            let inStartPeriod = clock.now - began < check.startPeriod
            // The immediate first probe is one more than Docker would have made by now, so it is free.
            if !inStartPeriod && attempt > 1 { failures += 1 }
            if failures >= check.retries {
                throw BackendError.commandFailed(
                    command: ShellWords.join(["container", "exec", "--", container] + check.command),
                    exitCode: exitCode(of: result),
                    message: "\(container) did not become healthy: its health check failed \(failures) time"
                        + "\(failures == 1 ? "" : "s") in a row (last result: \(result.summary)).")
            }
            try await Task.sleep(for: inStartPeriod ? check.startInterval : check.interval)
        }
    }

    /// Waits until `container` is no longer running.
    ///
    /// - Parameter report: called on every look with the seconds waited so far.
    static func untilCompleted(
        container: String, backend: any ContainerBackend, output: LineStream.Continuation,
        report: @MainActor (Int) -> Void
    ) async throws {
        let clock = ContinuousClock()
        let began = clock.now
        while true {
            try Task.checkCancellation()
            let current = try await backend.inspectContainer(container)
            if !current.isRunning {
                output.yield(
                    OutputLine("\(container) has stopped. Its exit code is not reported by the runtime."))
                return
            }
            await report(Int((clock.now - began).components.seconds))
            try await Task.sleep(for: completionPollInterval)
        }
    }

    /// One probe, limited to the check's `timeout` (the exec is cancelled when it takes longer).
    static func probe(container: String, check: ComposeHealthcheck, backend: any ContainerBackend) async -> Probe {
        await withTaskGroup(of: Probe?.self) { group in
            group.addTask {
                do {
                    let result = try await backend.execCapture(
                        container, command: check.command, workingDirectory: nil)
                    if result.exitCode == 0 { return .passed }
                    let text = result.stderr.isEmpty ? result.stdout : result.stderr
                    let lastLine = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
                    return .failed(exitCode: result.exitCode, output: lastLine)
                } catch {
                    return Task.isCancelled ? nil : .error(BackendError(wrapping: error))
                }
            }
            group.addTask {
                do { try await Task.sleep(for: check.timeout) } catch { return nil }
                return .timedOut
            }
            defer { group.cancelAll() }
            for await result in group {
                if let result { return result }
            }
            return .error(.cancelled)
        }
    }

    private static func exitCode(of probe: Probe) -> Int32 {
        if case .failed(let code, _) = probe { return code }
        return 1
    }

    /// Throws when `container` is gone or has stopped: there is nothing left to wait for.
    private static func requireRunning(
        _ container: String, backend: any ContainerBackend, whileWaitingFor what: String
    ) async throws {
        let current: Container
        do { current = try await backend.inspectContainer(container) } catch {
            let wrapped = BackendError(wrapping: error)
            if case .notFound = wrapped { throw wrapped }
            return  // could not ask; the next probe will tell
        }
        if !current.isRunning {
            throw BackendError.other(
                "\(container) stopped before \(what). Look at its logs (`container logs \(container)`).")
        }
    }
}
