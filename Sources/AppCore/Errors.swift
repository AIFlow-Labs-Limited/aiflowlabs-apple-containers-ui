import ContainerKit
import Foundation

public extension BackendError {
    /// Normalizes any thrown error into a `BackendError` so the UI only ever renders one error type.
    init(wrapping error: any Error) {
        if let backend = error as? BackendError {
            self = backend
        } else if error is CancellationError {
            self = .cancelled
        } else {
            self = .other(error.localizedDescription)
        }
    }

    /// Whether this error means "show a full-screen engine state" rather than an inline banner.
    var isEngineLevel: Bool {
        switch self {
        case .systemNotRunning, .cliNotInstalled: return true
        default: return false
        }
    }
}
