import ContainerKit
import Foundation

/// How the app chooses its backend. `CONTAINER_DESKTOP_BACKEND=mock` forces fixtures (used by previews,
/// UI tests and `make run-mock`).
public enum BackendSelection: String, Sendable {
    case cli, mock

    public static var fromEnvironment: BackendSelection {
        BackendSelection(rawValue: ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_BACKEND"]?.lowercased() ?? "")
            ?? .cli
    }
}
