import Foundation
import Observation
import ContainerKit

/// Shared shape of every resource store: loading flag, last error, refresh, and `perform` for actions.
@MainActor
public protocol BackendStore: AnyObject {
    var isLoading: Bool { get set }
    var lastError: BackendError? { get set }
    /// Reloads from the backend. Never throws; failures land in `lastError`.
    func refresh() async
}

public extension BackendStore {
    /// Runs an action, captures its error in `lastError`, then refreshes. Returns `true` on success.
    @discardableResult
    func perform(_ action: () async throws -> Void) async -> Bool {
        var failure: BackendError?
        do { try await action() } catch { failure = BackendError(wrapping: error) }
        await refresh()
        if let failure { lastError = failure }
        return failure == nil
    }

    /// Loads a value with `isLoading` toggled; on failure records `lastError` and returns `nil`.
    func load<T>(_ fetch: () async throws -> T) async -> T? {
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await fetch()
            lastError = nil
            return value
        } catch {
            lastError = BackendError(wrapping: error)
            return nil
        }
    }

    func clearError() { lastError = nil }
}

/// Stores with a `Poller`. Views call `startPolling()` in `.task` and `stopPolling()` in `.onDisappear`.
@MainActor
public protocol PollingStore: BackendStore {
    var poller: Poller { get }
}

public extension PollingStore {
    func startPolling() { poller.start() }
    func stopPolling() { poller.stop() }
}

/// Conditions shared by all pollers: polling pauses while the engine is down or the app is inactive.
@MainActor
@Observable
public final class PollingGate {
    public var engineRunning: Bool
    public var appActive: Bool
    /// Base interval (from Settings → General → Polling interval).
    public var interval: Duration

    public init(engineRunning: Bool = false, appActive: Bool = true, interval: Duration = .seconds(2)) {
        self.engineRunning = engineRunning
        self.appActive = appActive
        self.interval = interval
    }

    /// Whether a poller that requires the engine may fire now.
    public func isOpen(requiresEngine: Bool) -> Bool { appActive && (!requiresEngine || engineRunning) }
}
