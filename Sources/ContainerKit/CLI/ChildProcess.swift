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
    private let stdoutContinuation: AsyncStream<Data>.Continuation
    private let stderrContinuation: AsyncStream<Data>.Continuation

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
        forward(outPipe.fileHandleForReading, to: outContinuation)
        forward(errPipe.fileHandleForReading, to: errContinuation)

        let (exitStream, exitContinuation) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            exitContinuation.yield(finished.terminationReason == .uncaughtSignal ? 128 + status : status)
            exitContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            outContinuation.finish()
            errContinuation.finish()
            throw BackendError.commandFailed(command: display, exitCode: -1, message: error.localizedDescription)
        }

        if let inPipe, let stdin {
            let writer = inPipe.fileHandleForWriting
            // Written off the caller's task so a child that does not read stdin cannot stall us.
            Task.detached {
                try? writer.write(contentsOf: stdin)
                try? writer.close()
            }
        }

        return ChildProcess(
            process: process, display: display, stdout: outStream, stderr: errStream, exit: exitStream,
            stdoutContinuation: outContinuation, stderrContinuation: errContinuation)
    }

    private static func forward(_ handle: FileHandle, to continuation: AsyncStream<Data>.Continuation) {
        handle.readabilityHandler = { readable in
            let chunk = readable.availableData
            if chunk.isEmpty {
                readable.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(chunk)
            }
        }
    }

    /// Ends both pipe streams even if a grandchild still holds the write ends open.
    func finishPipes() {
        stdoutContinuation.finish()
        stderrContinuation.finish()
    }

    /// Waits for the exit status.
    func waitForExit() async -> Int32 {
        for await code in exit { return code }
        return -1
    }

    /// Sends SIGTERM, then SIGKILL after `grace` if the child is still alive.
    func terminate(grace: Duration) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        ChildProcess.signal(SIGTERM, to: pid)
        let process = self.process
        Task.detached {
            try? await Task.sleep(for: grace)
            if process.isRunning { ChildProcess.signal(SIGKILL, to: pid) }
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
