import Foundation

/// Outcome of a child process that ran to completion.
public struct ProcessResult: Hashable, Sendable {
    /// Exit status; `128 + signal` when the process was killed by a signal.
    public var exitCode: Int32
    /// Everything the process wrote to stdout.
    public var stdout: Data
    /// Everything the process wrote to stderr.
    public var stderr: Data

    /// Creates a result (used by fake runners in tests).
    public init(exitCode: Int32 = 0, stdout: Data = Data(), stderr: Data = Data()) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// Convenience initializer taking text output.
    public init(exitCode: Int32 = 0, stdout: String, stderr: String = "") {
        self.init(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }

    /// stdout decoded as UTF-8 (lossy).
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    /// stderr decoded as UTF-8 (lossy).
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs external commands. `CLIBackend` depends on this protocol so tests can inject a recording fake.
///
/// In both methods `arguments[0]` is the absolute path of the executable.
public protocol CommandRunning: Sendable {
    /// Runs a command to completion and captures its output. A non-zero exit is *not* an error here;
    /// callers inspect `exitCode`. Throws `BackendError.cancelled` on task cancellation and
    /// `BackendError.commandFailed` on timeout or launch failure.
    func run(_ arguments: [String], stdin: Data?, timeout: Duration?, environment: [String: String]) async throws -> ProcessResult

    /// Streams stdout/stderr line by line while the command runs. The stream finishes by throwing
    /// `BackendError.commandFailed` on a non-zero exit; cancelling the consumer kills the process.
    func stream(_ arguments: [String], environment: [String: String]) -> LineStream
}

extension CommandRunning {
    /// `run` with no stdin, no timeout and no extra environment unless given.
    public func run(_ arguments: [String], stdin: Data? = nil, timeout: Duration? = nil) async throws -> ProcessResult {
        try await run(arguments, stdin: stdin, timeout: timeout, environment: [:])
    }

    /// `stream` with no extra environment.
    public func stream(_ arguments: [String]) -> LineStream {
        stream(arguments, environment: [:])
    }
}

/// `Foundation.Process` based runner.
///
/// * stdout and stderr are drained concurrently (no full-pipe deadlocks).
/// * Cancellation sends SIGTERM, then SIGKILL after `killGracePeriod`.
/// * The child environment always has a sane `PATH` and no terminal/color variables.
public struct ProcessRunner: CommandRunning {
    /// Directories that are always on the child's `PATH`, ahead of the inherited entries.
    public static let basePath = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
    /// Variables removed from the inherited environment so the CLI never emits colors or TTY control codes.
    public static let strippedVariables: Set<String> = ["TERM", "COLORTERM", "CLICOLOR", "CLICOLOR_FORCE", "FORCE_COLOR", "TERM_PROGRAM"]

    /// Time between SIGTERM and SIGKILL when a child must be stopped.
    public var killGracePeriod: Duration
    /// How long to keep reading pipes after the child exited (a grandchild may hold them open).
    public var drainGracePeriod: Duration

    /// Creates a runner.
    public init(killGracePeriod: Duration = .seconds(2), drainGracePeriod: Duration = .seconds(2)) {
        self.killGracePeriod = killGracePeriod
        self.drainGracePeriod = drainGracePeriod
    }

    /// The environment a child receives: the current one minus terminal/color variables, with `PATH`
    /// prefixed by `basePath`, `NO_COLOR=1`, then `overrides` applied on top.
    public static func childEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment, overrides: [String: String] = [:]
    ) -> [String: String] {
        var env = base.filter { !strippedVariables.contains($0.key) }
        var path = basePath
        for entry in (base["PATH"] ?? "").split(separator: ":").map(String.init) where !path.contains(entry) {
            path.append(entry)
        }
        env["PATH"] = path.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env.merge(overrides) { _, new in new }
        return env
    }

    private enum Event: Sendable {
        case stdout(Data), stderr(Data), exit(Int32), timedOut, drainExpired, ignored
    }

    /// See `CommandRunning.run`.
    public func run(
        _ arguments: [String], stdin: Data?, timeout: Duration?, environment: [String: String]
    ) async throws -> ProcessResult {
        if Task.isCancelled { throw BackendError.cancelled }
        let child = try ChildProcess.launch(arguments, stdin: stdin, environment: Self.childEnvironment(overrides: environment))
        let grace = killGracePeriod
        let drain = drainGracePeriod

        let (result, timedOut) = await withTaskCancellationHandler {
            await withTaskGroup(of: Event.self) { group -> (ProcessResult, Bool) in
                group.addTask { .stdout(await ChildProcess.collect(child.stdout)) }
                group.addTask { .stderr(await ChildProcess.collect(child.stderr)) }
                group.addTask { .exit(await child.waitForExit()) }
                if let timeout {
                    group.addTask { (try? await Task.sleep(for: timeout)) == nil ? .ignored : .timedOut }
                }
                var out: Data?, err: Data?, code: Int32?, timedOut = false
                while let event = await group.next() {
                    switch event {
                    case .stdout(let data): out = data
                    case .stderr(let data): err = data
                    case .exit(let status):
                        code = status
                        group.addTask { (try? await Task.sleep(for: drain)) == nil ? .ignored : .drainExpired }
                    case .timedOut:
                        timedOut = true
                        child.terminate(grace: grace)
                    case .drainExpired: child.finishPipes()
                    case .ignored: break
                    }
                    if out != nil, err != nil, code != nil { break }
                }
                group.cancelAll()
                return (ProcessResult(exitCode: code ?? -1, stdout: out ?? Data(), stderr: err ?? Data()), timedOut)
            }
        } onCancel: {
            child.terminate(grace: grace)
        }

        if Task.isCancelled { throw BackendError.cancelled }
        if timedOut, let timeout {
            throw BackendError.commandFailed(
                command: child.display, exitCode: result.exitCode,
                message: "Timed out after \(timeout.components.seconds) s: \(child.display)")
        }
        return result
    }

    /// See `CommandRunning.stream`.
    public func stream(_ arguments: [String], environment: [String: String]) -> LineStream {
        let grace = killGracePeriod
        let drain = drainGracePeriod
        let env = Self.childEnvironment(overrides: environment)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let child = try ChildProcess.launch(arguments, stdin: nil, environment: env)
                    let (code, stderrTail) = await withTaskCancellationHandler {
                        await Self.pump(child, into: continuation, drain: drain)
                    } onCancel: {
                        child.terminate(grace: grace)
                    }
                    if Task.isCancelled {
                        continuation.finish(throwing: BackendError.cancelled)
                    } else if code != 0 {
                        let message = CLIErrorMapper.cleanMessage(stderrTail.joined(separator: "\n"))
                        continuation.finish(throwing: BackendError.commandFailed(command: child.display, exitCode: code, message: message))
                    } else {
                        continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum StreamEvent: Sendable {
        case pipeDone(stderrTail: [String]?), exit(Int32), drainExpired, ignored
    }

    /// Forwards both pipes as `OutputLine`s until the child exits; returns the exit code and the last
    /// stderr lines (used for the error message).
    private static func pump(
        _ child: ChildProcess, into continuation: LineStream.Continuation, drain: Duration
    ) async -> (Int32, [String]) {
        await withTaskGroup(of: StreamEvent.self) { group -> (Int32, [String]) in
            group.addTask {
                _ = await forwardLines(child.stdout, as: .stdout, into: continuation)
                return .pipeDone(stderrTail: nil)
            }
            group.addTask {
                .pipeDone(stderrTail: await forwardLines(child.stderr, as: .stderr, into: continuation))
            }
            group.addTask { .exit(await child.waitForExit()) }
            var pipesOpen = 2, code: Int32?, tail: [String] = []
            while let event = await group.next() {
                switch event {
                case .pipeDone(let stderrTail):
                    pipesOpen -= 1
                    if let stderrTail { tail = stderrTail }
                case .exit(let status):
                    code = status
                    group.addTask { (try? await Task.sleep(for: drain)) == nil ? .ignored : .drainExpired }
                case .drainExpired: child.finishPipes()
                case .ignored: break
                }
                if pipesOpen == 0, code != nil { break }
            }
            group.cancelAll()
            return (code ?? -1, tail)
        }
    }

    /// Yields each line of `chunks`; returns the last 200 lines (for stderr error messages).
    private static func forwardLines(
        _ chunks: AsyncStream<Data>, as stream: OutputLine.Stream, into continuation: LineStream.Continuation
    ) async -> [String] {
        var splitter = LineSplitter()
        var tail: [String] = []
        func emit(_ lines: [String]) {
            for line in lines {
                continuation.yield(OutputLine(line, stream: stream))
                tail.append(line)
                if tail.count > 200 { tail.removeFirst(tail.count - 200) }
            }
        }
        for await chunk in chunks { emit(splitter.feed(chunk)) }
        emit(splitter.flush())
        return tail
    }
}
