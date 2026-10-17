import Foundation
import ContainerKit

/// Periodically runs an action while its `PollingGate` is open.
///
/// * Reference counted: several views can `start()` the same poller; it stops when the last one calls `stop()`.
/// * Pauses (without firing) while the engine is down or the app is inactive.
/// * Exponential backoff on errors: `interval × 2^failures`, capped at 30 s.
@MainActor
public final class Poller {
    public static let maxBackoff: Duration = .seconds(30)

    public private(set) var isRunning = false
    /// Number of times the action actually ran (for tests/diagnostics).
    public private(set) var fireCount = 0
    public private(set) var consecutiveFailures = 0

    private let gate: PollingGate
    private let requiresEngine: Bool
    private let action: @MainActor () async throws -> Void
    private var clients = 0
    private var task: Task<Void, Never>?
    private var fixedInterval: Duration?

    public init(gate: PollingGate, requiresEngine: Bool = true, action: @escaping @MainActor () async throws -> Void) {
        self.gate = gate
        self.requiresEngine = requiresEngine
        self.action = action
    }

    /// Starts polling (or adds a client). `interval` overrides the gate's interval.
    public func start(interval: Duration? = nil) {
        clients += 1
        if let interval { fixedInterval = interval }
        guard task == nil else { return }
        isRunning = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = await self?.tick() else { return }
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// Removes a client; polling stops when none remain.
    public func stop() {
        clients = max(0, clients - 1)
        if clients == 0 { stopAll() }
    }

    /// Stops regardless of client count.
    public func stopAll() {
        clients = 0
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// Runs the action once now (ignores the gate). Used by manual refresh.
    public func fireNow() async { _ = await run() }

    private func tick() async -> Duration {
        let base = fixedInterval ?? gate.interval
        guard gate.isOpen(requiresEngine: requiresEngine) else { return min(base, .seconds(1)) }
        await run()
        return Self.delay(base: base, failures: consecutiveFailures)
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

    /// Backoff schedule: `base × 2^failures`, capped at `maxBackoff`.
    public static func delay(base: Duration, failures: Int) -> Duration {
        guard failures > 0 else { return base }
        let factor = 1 << min(failures, 8)
        return min(base * factor, maxBackoff)
    }
}
