import Foundation
import ContainerKit

/// Periodically runs an action while its `PollingGate` is open.
///
/// * Reference counted: several views can `start()` the same poller; it stops when the last one calls `stop()`.
///   `startBackground()` / `stopBackground()` add a separate kind of client (owned by `AppModel`) that keeps the
///   poller alive at `backgroundInterval` when no window shows it.
/// * Foreground rate: the gate's interval (or the `interval` passed to `init`/`start`), only while the app is
///   active. When the app is inactive — or only background clients remain — a poller with a `backgroundInterval`
///   keeps ticking at that slower rate; one without it pauses.
/// * Pauses (without firing) while the engine is down, if `requiresEngine`.
/// * Exponential backoff on errors: `interval × 2^failures`, capped at 30 s.
/// * Never runs two ticks at once: a restart waits for the previous loop to finish.
@MainActor
public final class Poller {
    public static let maxBackoff: Duration = .seconds(30)

    public private(set) var isRunning = false
    /// Number of times the action actually ran (for tests/diagnostics).
    public private(set) var fireCount = 0
    public private(set) var consecutiveFailures = 0
    /// Slow lane used while the app is inactive or only background clients remain. `nil` = pause instead.
    public var backgroundInterval: Duration?

    private let gate: PollingGate
    private let requiresEngine: Bool
    private let action: @MainActor () async throws -> Void
    private var clients = 0
    private var backgroundClients = 0
    private var task: Task<Void, Never>?
    private var sleeper: Task<Void, Never>?
    private var fixedInterval: Duration?
    private var isTicking = false

    /// - Parameters:
    ///   - interval: fixed foreground interval (overrides the gate's; e.g. 10 s for the status bar's disk usage).
    ///   - backgroundInterval: see the property.
    public init(gate: PollingGate, requiresEngine: Bool = true, interval: Duration? = nil,
                backgroundInterval: Duration? = nil, action: @escaping @MainActor () async throws -> Void) {
        self.gate = gate
        self.requiresEngine = requiresEngine
        self.fixedInterval = interval
        self.backgroundInterval = backgroundInterval
        self.action = action
        gate.register(self)
    }

    /// Starts polling (or adds a client). `interval` overrides the foreground interval.
    public func start(interval: Duration? = nil) {
        clients += 1
        if let interval { fixedInterval = interval }
        ensureLoop()
    }

    /// Removes a client; polling stops when no foreground or background clients remain.
    public func stop() {
        clients = max(0, clients - 1)
        if clients == 0 && backgroundClients == 0 { cancelLoop() }
    }

    /// Adds a background client (polls at `backgroundInterval`, ignoring `appActive`). Requires `backgroundInterval`.
    public func startBackground() {
        backgroundClients += 1
        ensureLoop()
    }

    public func stopBackground() {
        backgroundClients = max(0, backgroundClients - 1)
        if clients == 0 && backgroundClients == 0 { cancelLoop() }
    }

    /// Stops regardless of client count.
    public func stopAll() {
        clients = 0
        backgroundClients = 0
        cancelLoop()
    }

    /// Runs the action once now (ignores the gate). Used by manual refresh. Skipped if a tick is in progress.
    public func fireNow() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }
        _ = await run()
    }

    /// Ends the current sleep early so the next tick re-evaluates the gate now.
    public func wake() { sleeper?.cancel() }

    /// Foreground clients (views), for tests/diagnostics.
    public var foregroundClientCount: Int { clients }
    public var backgroundClientCount: Int { backgroundClients }

    // MARK: Loop

    private func ensureLoop() {
        guard task == nil else { return }
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                // Wait out a previous loop's in-flight tick (quick stop → start) so ticks never overlap.
                while self?.isTicking == true {
                    try? await Task.sleep(for: .milliseconds(10))
                    if Task.isCancelled { return }
                }
                guard let delay = await self?.tick(), !Task.isCancelled else { return }
                // `self` is not retained while sleeping, so an abandoned poller can deallocate.
                let sleeper = self?.makeSleeper(delay)
                await sleeper?.value
            }
        }
    }

    private func cancelLoop() {
        task?.cancel()
        task = nil
        sleeper?.cancel()
        sleeper = nil
        isRunning = false
    }

    private func makeSleeper(_ delay: Duration) -> Task<Void, Never> {
        let s = Task { _ = try? await Task.sleep(for: delay) }
        sleeper = s
        return s
    }

    /// The interval to wait after this tick, or `nil` when the poller should not fire now.
    func currentInterval() -> Duration? {
        let base = fixedInterval ?? gate.interval
        if clients > 0 && gate.isOpen(requiresEngine: requiresEngine) { return base }
        if let backgroundInterval, gate.isOpenInBackground(requiresEngine: requiresEngine),
           backgroundClients > 0 || (clients > 0 && !gate.appActive) {
            return max(base, backgroundInterval)
        }
        return nil
    }

    private func tick() async -> Duration {
        guard let interval = currentInterval() else {
            // Closed: re-check soon (the gate also wakes us when it opens).
            return min(fixedInterval ?? gate.interval, .seconds(1))
        }
        isTicking = true
        await run()
        isTicking = false
        return Self.delay(base: interval, failures: consecutiveFailures)
    }

    @discardableResult
    private func run() async -> Bool {
        fireCount += 1
        do {
            try await action()
            consecutiveFailures = 0
            return true
        } catch {
            consecutiveFailures += 1
            return false
        }
    }

    /// Backoff schedule: `base × 2^failures`, capped at `maxBackoff` (never below `base`).
    public static func delay(base: Duration, failures: Int) -> Duration {
        guard failures > 0 else { return base }
        let factor = 1 << min(failures, 8)
        return max(base, min(base * factor, maxBackoff))
    }
}
