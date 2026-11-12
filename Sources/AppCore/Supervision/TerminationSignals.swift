import Foundation
import Synchronization

/// Write end of the pipe the signal handler reports to (−1 until `TerminationSignals.stream` sets it up).
private let signalPipeWriteEnd = Atomic<Int32>(-1)

/// SIGTERM and SIGINT as an async sequence, for the headless helper to stop cleanly when launchd asks.
///
/// The classic self-pipe: the handler only writes the signal number to a pipe (async-signal-safe), a thread
/// blocked on the other end hands it to the stream. Handlers, unlike a blocked or ignored signal, are reset in
/// child processes, so `container` commands the helper spawns still die on SIGTERM as usual.
public enum TerminationSignals {
    /// Installs handlers for `signals` and yields each one received. Call once per process.
    public static func stream(_ signals: [Int32] = [SIGTERM, SIGINT]) -> AsyncStream<Int32> {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { return AsyncStream { $0.finish() } }
        let readEnd = ends[0]
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        signalPipeWriteEnd.store(ends[1], ordering: .sequentiallyConsistent)
        for number in signals {
            signal(number) { received in
                var byte = UInt8(truncatingIfNeeded: received)
                let fd = signalPipeWriteEnd.load(ordering: .sequentiallyConsistent)
                if fd >= 0 { _ = write(fd, &byte, 1) }
            }
        }
        return AsyncStream { continuation in
            Thread.detachNewThread {
                var byte: UInt8 = 0
                while true {
                    let count = read(readEnd, &byte, 1)
                    if count == 1 {
                        continuation.yield(Int32(byte))
                    } else if count == 0 || errno != EINTR {
                        break
                    }
                }
                continuation.finish()
            }
        }
    }
}
