import Foundation
import ServiceManagement

/// Whether the background helper is set up to run at login.
public enum BackgroundSupervisionStatus: Equatable, Sendable {
    /// Not registered: restart policies are enforced only while the app runs.
    case disabled
    /// Registered and allowed: the helper runs now and at every login.
    case enabled
    /// Registered, but the user has to allow it in System Settings › General › Login Items.
    case requiresApproval
    /// It cannot be set up from this copy of the app (the reason, for the user).
    case unavailable(String)

    /// Registered with macOS, allowed or not.
    public var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

/// Registers and removes the background helper. Views never talk to ServiceManagement; `SettingsStore` does,
/// through this.
public protocol BackgroundSupervisionService: Sendable {
    /// The state as macOS reports it now.
    func status() -> BackgroundSupervisionStatus
    /// Registers the helper; macOS starts it right away and at every login.
    func enable() throws
    /// Removes the helper; macOS stops it.
    func disable() throws
}

/// The helper as a per-user LaunchAgent registered with `SMAppService.agent(plistName:)`.
///
/// The agent's property list ships inside the app (`Contents/Library/LaunchAgents/`), so nothing is written to
/// `~/Library/LaunchAgents` and the helper is listed (and can be switched off) under System Settings › General ›
/// Login Items. It runs the app's own executable with `--supervise`.
public struct LoginAgentSupervisionService: BackgroundSupervisionService {
    /// File name of the agent's property list in `Contents/Library/LaunchAgents/`.
    public static let plistName = "io.aiflowlabs.containerdesktop.supervisor.plist"
    /// The launchd label of the agent.
    public static let label = "io.aiflowlabs.containerdesktop.supervisor"
    /// Argument that makes the executable run as the helper instead of opening the app.
    public static let superviseArgument = "--supervise"

    /// The service for the running app bundle.
    public init() {}

    private var agent: SMAppService { SMAppService.agent(plistName: Self.plistName) }

    /// Whether this process runs from an app bundle that carries the agent's property list.
    private var bundleHasAgent: Bool {
        let plist = Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/\(Self.plistName)")
        return FileManager.default.fileExists(atPath: plist.path)
    }

    public func status() -> BackgroundSupervisionStatus {
        guard bundleHasAgent else {
            return .unavailable("Only available in the packaged app (not when run with `swift run`).")
        }
        switch agent.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    public func enable() throws { try agent.register() }

    public func disable() throws {
        let agent = agent
        // Unregistering something that is not registered is an error in ServiceManagement; here it is the goal.
        guard agent.status == .enabled || agent.status == .requiresApproval else { return }
        try agent.unregister()
    }
}
