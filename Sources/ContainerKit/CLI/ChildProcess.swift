import Darwin
import Foundation

/// A launched child process whose pipes are exposed as async chunk streams.
///
/// Pipes are drained by `readabilityHandler`s that forward chunks into `AsyncStream`s, so stdout and stderr
/// are always read concurrently and a chatty child can never block on a full pipe buffer.
struct ChildProcess: Sendable {
    let process: Process
    /// The command as a shell-quoted one-liner, for error messages.
    let display: String
    let stdout: AsyncStream<Data>
    let stderr: AsyncStream<Data>
    /// Yields the exit status once (128 + signal number when killed by a signal).
    let exit: AsyncStream<Int32>
    private let stdoutReader: PipeReader
    private let stderrReader: PipeReader

    /// Starts `arguments[0]` with the remaining arguments.
    static func launch(_ arguments: [String], stdin: Data?, environment: [String: String]) throws -> ChildProcess {
        guard let executable = arguments.first else {
            throw BackendError.other("Cannot run an empty command line.")
        }
        let display = CommandLine(executable: executable, arguments: Array(arguments.dropFirst())).display
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe: Pipe? = stdin == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice

        let (outStream, outContinuation) = AsyncStream.makeStream(of: Data.self)
        let (errStream, errContinuation) = AsyncStream.makeStream(of: Data.self)
        let outReader = PipeReader(outPipe.fileHandleForReading, continuation: outContinuation)
        let errReader = PipeReader(errPipe.fileHandleForReading, continuation: errContinuation)

        let (exitStream, exitContinuation) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            exitContinuation.yield(finished.terminationReason == .uncaughtSignal ? 128 + status : status)
            exitContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            outReader.close()
            errReader.close()
            throw BackendError.commandFailed(command: display, exitCode: -1, message: error.localizedDescription)
        }

        if let inPipe, let stdin {
            let writer = inPipe.fileHandleForWriting
            // A child that exits before reading stdin must yield EPIPE, never a process-killing SIGPIPE.
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            // Written off the caller's task so a child that does not read stdin cannot stall us.
            Task.detached {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }

        return ChildProcess(
            process: process, display: display, stdout: outStream, stderr: errStream, exit: exitStream,
            stdoutReader: outReader, stderrReader: errReader)
    }

    /// Ends both pipe streams even if a grandchild still holds the write ends open: removes the readability
    /// handlers, closes our read ends and finishes the streams.
    func finishPipes() {
        stdoutReader.close()
        stderrReader.close()
    }

    /// Waits for the exit status.
    func waitForExit() async -> Int32 {
        for await code in exit { return code }
        return -1
    }

    /// Sends SIGTERM, then SIGKILL to the whole process group after `grace` (grandchildren included, even
    /// when the group leader already exited).
    func terminate(grace: Duration) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        ChildProcess.signal(SIGTERM, to: pid)
        Task.detached {
            try? await Task.sleep(for: grace)
            // Fails harmlessly with ESRCH when the group is already gone.
            _ = killpg(pid, SIGKILL)
            _ = kill(pid, SIGKILL)
        }
    }

    /// Signals the child's whole process group when it leads one, otherwise just the child.
    private static func signal(_ signal: Int32, to pid: pid_t) {
        if getpgid(pid) == pid { killpg(pid, signal) } else { kill(pid, signal) }
    }

    /// Concatenates a chunk stream.
    static func collect(_ chunks: AsyncStream<Data>) async -> Data {
        var data = Data()
        for await chunk in chunks { data.append(chunk) }
        return data
    }
}

/// Forwards one pipe's read end into an `AsyncStream`. Reading and closing are serialized by a lock, so a
/// readability callback can never touch a handle that `close()` already closed.
private final class PipeReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let continuation: AsyncStream<Data>.Continuation
    private var closed = false

    init(_ handle: FileHandle, continuation: AsyncStream<Data>.Continuation) {
        self.handle = handle
        self.continuation = continuation
        // Strong capture on purpose: the cycle is broken when `closeLocked()` clears the handler.
        handle.readabilityHandler = { _ in self.readAvailable() }
    }

    private func readAvailable() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let chunk = handle.availableData
        if chunk.isEmpty {
            closeLocked()
        } else {
            continuation.yield(chunk)
        }
    }

    /// Idempotent: clears the handler, closes the fd and finishes the stream.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    private func closeLocked() {
        guard !closed else { return }
        closed = true
        handle.readabilityHandler = nil
        try? handle.close()
        continuation.finish()
    }
}
