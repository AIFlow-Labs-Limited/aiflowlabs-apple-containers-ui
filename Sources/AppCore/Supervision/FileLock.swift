import Foundation

/// An advisory lock on a file (`flock`), held by this process until `unlock()` or until the process ends.
///
/// The kernel drops the lock when the holder dies, however it dies, so there is no stale lock to clean up and
/// no timing to guess. The file is opened close-on-exec: a `container` child process never inherits the lock.
/// Not `Sendable`: keep an instance inside one actor.
public final class FileLock {
    private let path: String
    private var descriptor: Int32 = -1

    /// A lock on the file at `url`; nothing is opened until `tryLock()` or `lock()`.
    public init(url: URL) { path = url.path }

    deinit { if descriptor >= 0 { close(descriptor) } }

    /// Whether this instance holds the lock.
    public var isHeld: Bool { descriptor >= 0 }

    /// Takes the lock if nobody else holds it. Returns whether this instance holds it now.
    public func tryLock() -> Bool { acquire(blocking: false) }

    /// Waits for the lock. Returns `false` only when the file cannot be opened.
    public func lock() -> Bool { acquire(blocking: true) }

    /// Gives the lock up (a no-op when it is not held).
    public func unlock() {
        guard descriptor >= 0 else { return }
        close(descriptor)  // closing the only descriptor of this open file releases the flock
        descriptor = -1
    }

    /// Whether some other holder (another process, or another `FileLock` in this one) has the file locked.
    /// A file that does not exist is not locked.
    public static func isLockedElsewhere(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 { return false }
        return errno == EWOULDBLOCK
    }

    private func acquire(blocking: Bool) -> Bool {
        if descriptor >= 0 { return true }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return false }
        var result = flock(fd, blocking ? LOCK_EX : LOCK_EX | LOCK_NB)
        while result != 0 && errno == EINTR { result = flock(fd, blocking ? LOCK_EX : LOCK_EX | LOCK_NB) }
        guard result == 0 else {
            close(fd)
            return false
        }
        descriptor = fd
        return true
    }
}
