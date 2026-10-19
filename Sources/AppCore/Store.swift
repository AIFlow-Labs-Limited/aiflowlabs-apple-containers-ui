import Foundation
import Observation
import ContainerKit

/// Shared shape of every resource store: loading flag, errors, refresh, and `perform` for actions.
///
/// Errors are split by owner so a poll tick can never wipe an action's failure:
/// * `loadError` belongs to `refresh()` / `load` — set on a failed fetch, cleared by the next successful one.
/// * `actionError` belongs to `perform` / `performEach` — set when an action fails, cleared only by
///   `clearError()` (the banner's dismiss button) or by the start of the next action.
/// * `lastError` (what banners show) is `actionError ?? loadError`.
///
/// Conformers declare `loadError` and `actionError` as stored properties and `lastError` as
/// `{ get { actionError ?? loadError } set { … } }` (see `ImagesStore`). A store that still only declares a
/// stored `lastError` keeps compiling: the defaults below map both new properties onto it (legacy behaviour).
@MainActor
public protocol BackendStore: AnyObject {
    var isLoading: Bool { get set }
    /// What banners show: `actionError ?? loadError`. Setting `nil` clears both; setting a value sets `actionError`.
    var lastError: BackendError? { get set }
    /// Error of the last refresh (`nil` after a successful one).
    var loadError: BackendError? { get set }
    /// Error of the last user action (`nil` until one fails; survives poll ticks).
    var actionError: BackendError? { get set }
    /// Reloads from the backend. Never throws; failures land in `loadError`.
    func refresh() async
}

public extension BackendStore {
    // Legacy fallbacks for stores that only have a stored `lastError` (do NOT combine these defaults with a
    // computed `lastError` that reads them — that would recurse).
    var loadError: BackendError? {
        get { lastError }
        set { lastError = newValue }
    }

    var actionError: BackendError? {
        get { lastError }
        set { lastError = newValue }
    }
}

/// Outcome of `performEach`: which ids succeeded and which failed (with their error), in input order.
public struct BulkResult: Sendable {
    public var succeeded: [String] = []
    public var failed: [(id: String, error: BackendError)] = []

    public init(succeeded: [String] = [], failed: [(id: String, error: BackendError)] = []) {
        self.succeeded = succeeded
        self.failed = failed
    }

    public var allSucceeded: Bool { failed.isEmpty }
    public var total: Int { succeeded.count + failed.count }

    /// One error summarising the failures ("Failed for 2 of 10: a (msg); b (msg)"), or `nil` when all succeeded.
    /// A single failure is returned unchanged so its `failedCommand` stays visible.
    public var combinedError: BackendError? {
        guard let first = failed.first else { return nil }
        if failed.count == 1 && succeeded.isEmpty { return first.error }
        let details = failed.map { "\($0.id) (\($0.error.errorDescription ?? "failed"))" }.joined(separator: "; ")
        return .other("Failed for \(failed.count) of \(total): \(details)")
    }

    /// "Deleted 8 of 10" style summary.
    public func summary(verb: String) -> String {
        failed.isEmpty ? "\(verb) \(succeeded.count)" : "\(verb) \(succeeded.count) of \(total)"
    }
}

/// Per-store, per-call-site sequence numbers so a slow, older `load` cannot overwrite a newer result.
@MainActor
enum LoadSequencer {
    private struct Key: Hashable { let store: ObjectIdentifier; let site: String }
    private static var latest: [Key: Int] = [:]
    private static var inFlight: [ObjectIdentifier: Int] = [:]

    static func begin(_ store: AnyObject, site: String) -> Int {
        let key = Key(store: ObjectIdentifier(store), site: site)
        let next = (latest[key] ?? 0) + 1
        latest[key] = next
        inFlight[ObjectIdentifier(store), default: 0] += 1
        return next
    }

    /// Ends a load; returns whether `generation` is still the newest for this call site.
    static func end(_ store: AnyObject, site: String, generation: Int) -> (isCurrent: Bool, stillLoading: Bool) {
        let id = ObjectIdentifier(store)
        let remaining = max(0, (inFlight[id] ?? 1) - 1)
        inFlight[id] = remaining == 0 ? nil : remaining
        return (latest[Key(store: id, site: site)] == generation, remaining > 0)
    }
}

public extension BackendStore {
    /// Runs an action, records its failure in `actionError`, then refreshes. Returns `true` on success.
    /// Starting an action clears the previous `actionError`.
    @discardableResult
    func perform(_ action: () async throws -> Void) async -> Bool {
        if case .failure = await attempt(action) { return false }
        return true
    }

    /// Like `perform`, but hands back the error too (it is also stored in `actionError`).
    @discardableResult
    func attempt(_ action: () async throws -> Void) async -> Result<Void, BackendError> {
        actionError = nil
        var failure: BackendError?
        do { try await action() } catch { failure = BackendError(wrapping: error) }
        await refresh()
        if let failure {
            actionError = failure
            return .failure(failure)
        }
        return .success(())
    }

    /// Runs `action` for every id independently (a failure does not skip the rest), refreshes once, and stores a
    /// combined `actionError` when anything failed.
    @discardableResult
    func performEach(ids: [String], _ action: (String) async throws -> Void) async -> BulkResult {
        actionError = nil
        var result = BulkResult()
        for id in ids {
            do {
                try await action(id)
                result.succeeded.append(id)
            } catch {
                result.failed.append((id, BackendError(wrapping: error)))
            }
        }
        await refresh()
        actionError = result.combinedError
        return result
    }

    /// Loads a value with `isLoading` toggled; on failure records `loadError` and returns `nil`.
    ///
    /// Results are sequenced per store and per call site (`site`, defaulting to the caller's function name): if a
    /// newer `load` from the same site started while this one was in flight, this result (value *and* error) is
    /// dropped and `nil` is returned.
    func load<T>(site: String = #function, _ fetch: () async throws -> T) async -> T? {
        let generation = LoadSequencer.begin(self, site: site)
        isLoading = true
        var value: T?
        var failure: BackendError?
        do { value = try await fetch() } catch { failure = BackendError(wrapping: error) }
        let (isCurrent, stillLoading) = LoadSequencer.end(self, site: site, generation: generation)
        if !stillLoading { isLoading = false }
        guard isCurrent else { return nil }
        loadError = failure
        return value
    }

    /// Dismisses whatever the banner shows (both the action and the load error).
    func clearError() {
        actionError = nil
        loadError = nil
    }
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

/// Conditions shared by all pollers: polling pauses while the engine is down or the app is inactive
/// (pollers with a `backgroundInterval` keep ticking slowly while inactive).
@MainActor
@Observable
public final class PollingGate {
    public var engineRunning: Bool {
        didSet { if engineRunning && !oldValue { wakePollers() } }
    }
    public var appActive: Bool {
        didSet { if appActive && !oldValue { wakePollers() } }
    }
    /// Base interval (from Settings → General → Polling interval).
    public var interval: Duration

    @ObservationIgnored private var pollers: [WeakPoller] = []

    public init(engineRunning: Bool = false, appActive: Bool = true, interval: Duration = .seconds(2)) {
        self.engineRunning = engineRunning
        self.appActive = appActive
        self.interval = interval
    }

    /// Whether a poller that requires the engine may fire now at its normal (foreground) rate.
    public func isOpen(requiresEngine: Bool) -> Bool { appActive && (!requiresEngine || engineRunning) }

    /// Whether a poller with a background lane may fire now (ignores `appActive`).
    public func isOpenInBackground(requiresEngine: Bool) -> Bool { !requiresEngine || engineRunning }

    func register(_ poller: Poller) {
        pollers.removeAll { $0.poller == nil }
        pollers.append(WeakPoller(poller: poller))
    }

    /// Cuts every poller's current sleep short (the app became active or the engine came up).
    private func wakePollers() {
        pollers.removeAll { $0.poller == nil }
        for entry in pollers { entry.poller?.wake() }
    }

    private struct WeakPoller { weak var poller: Poller? }
}
