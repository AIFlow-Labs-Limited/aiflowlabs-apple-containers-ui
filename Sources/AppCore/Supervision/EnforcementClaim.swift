import Foundation

/// The files the app and the background helper share
/// (`~/Library/Application Support/Container Desktop/Supervision/`).
public struct SupervisionPaths: Sendable, Equatable {
    /// The folder holding everything below.
    public let directory: URL

    /// Files in `directory`.
    public init(directory: URL) { self.directory = directory }

    /// The folder next to the app's build history.
    public static var standard: SupervisionPaths {
        SupervisionPaths(
            directory: URL.applicationSupportDirectory
                .appending(path: "Container Desktop", directoryHint: .isDirectory)
                .appending(path: "Supervision", directoryHint: .isDirectory))
    }

    /// Stops and engine stops the user asked for (`FileSupervisionState`).
    public var state: URL { directory.appending(path: "state.json") }
    /// Locked by whichever process enforces restart policies right now.
    public var enforcerLock: URL { directory.appending(path: "enforcer.lock") }
    /// Locked by the background helper for as long as it runs, enforcing or not.
    public var helperLock: URL { directory.appending(path: "helper.lock") }
}

/// Decides which process may enforce restart policies: exactly one at a time, the helper when it runs.
///
/// Two advisory file locks (`FileLock`), both released by the kernel when their holder dies:
///
/// * `enforcerLock`: only its holder restarts containers.
/// * `helperLock`: held by the helper for its whole life. The app looks at it before every pass and, while a
///   helper is alive, gives `enforcerLock` up and stands down; the helper takes it on its next pass.
///
/// So the hand-over needs no message and no timing assumption: between the app letting go and the helper taking
/// over nobody enforces (seconds), and never both. When the helper goes away (switched off, crashed, killed)
/// the app takes the lock back on its next pass.
@MainActor
public final class EnforcementClaim {
    /// Who is asking.
    public enum Role: Sendable {
        /// The app: enforces unless a helper is alive.
        case app
        /// The background helper: enforces as soon as the app has let go.
        case helper
    }

    /// Who this claim is for.
    public let role: Role
    private let paths: SupervisionPaths
    private let enforcer: FileLock
    private let helper: FileLock

    /// A claim for `role` on the lock files in `paths`. Nothing is locked until `hold()`.
    public init(role: Role, paths: SupervisionPaths = .standard) {
        self.role = role
        self.paths = paths
        enforcer = FileLock(url: paths.enforcerLock)
        helper = FileLock(url: paths.helperLock)
    }

    /// Whether this process is the enforcer right now.
    public var isHeld: Bool { enforcer.isHeld }

    /// Takes (or keeps) the right to enforce. Cheap when already held; call it before every pass.
    public func hold() -> Bool {
        switch role {
        case .app:
            if FileLock.isLockedElsewhere(paths.helperLock) {
                enforcer.unlock()
                return false
            }
            return enforcer.tryLock()
        case .helper:
            // Announce first: the app only lets go once it sees a helper.
            guard helper.tryLock() else { return false }
            return enforcer.tryLock()
        }
    }

    /// Gives everything up (the helper is stopping, or enforcement was switched off).
    public func release() {
        enforcer.unlock()
        helper.unlock()
    }
}
