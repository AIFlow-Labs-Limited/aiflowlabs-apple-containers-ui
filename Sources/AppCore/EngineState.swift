import ContainerKit
import Foundation

/// State of the `container` system as the UI presents it (drives `EngineGateView`).
public enum EngineState: Equatable, Sendable {
    /// First probe in flight.
    case checking
    /// CLI binary missing.
    case notInstalled(searchedPaths: [String])
    /// CLI present, apiserver down.
    case stopped
    /// `container system start` in flight (may download the kernel on first run).
    case starting
    case running(SystemStatus)
    /// Probe failed for a reason other than "not running"/"not installed".
    case error(BackendError)

    public var isRunning: Bool { if case .running = self { return true } else { return false } }

    public var status: SystemStatus? { if case .running(let s) = self { return s } else { return nil } }

    /// Short label for the status bar / menu bar.
    public var label: String {
        switch self {
        case .checking: return "Checking…"
        case .notInstalled: return "Not installed"
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .error: return "Error"
        }
    }

    /// Server (or client) version when known.
    public var version: String? {
        guard let s = status else { return nil }
        return s.server?.version ?? s.client?.version
    }
}
