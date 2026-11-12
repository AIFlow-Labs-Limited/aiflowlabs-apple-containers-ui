import ContainerKit
import Foundation

/// The background helper's loop: restart-policy enforcement without the app's windows, stores or pollers.
///
/// `ContainerDesktop --supervise` (started at login by the LaunchAgent) builds one of these around a
/// `CLIBackend` and a `RestartSupervisor`, and calls `run()`. Each pass (`step()`):
///
/// 1. reads the "Enforce restart policies" switch; off means idle,
/// 2. takes the right to enforce (`EnforcementClaim`); while the app still holds it, waits,
/// 3. lists the containers (one `container list` process) and hands the list to the supervisor.
///
/// It is cheap when there is nothing to do: one pass every `Cadence.active` seconds while containers with a
/// policy exist, every `Cadence.idle` seconds otherwise, and the same error backoff as `Poller` while the
/// container system is down or the CLI is missing. Only a restart that is already scheduled brings the next pass
/// forward. It never starts the container system itself.
@MainActor
public final class BackgroundSupervisor {
    /// How often the helper looks.
    public struct Cadence: Sendable, Equatable {
        /// Between passes while at least one container has a restart policy (the app's background rate).
        public var active: Duration = .seconds(10)
        /// Between passes while no container has one, or enforcement is switched off.
        public var idle: Duration = .seconds(30)

        /// The shortest wait, used when a restart attempt is due sooner than the next regular pass.
        public var minimum: Duration = .milliseconds(500)

        /// 10 s with supervised containers, 30 s without.
        public init() {}
    }

    /// What the helper is doing, for its log and for tests.
    public enum Phase: Equatable, Sendable {
        /// No pass made yet.
        case starting
        /// "Enforce restart policies" is off.
        case switchedOff
        /// The app is still the enforcer.
        case standingBy
        /// The container system is not running, or the `container` CLI is not installed.
        case waitingForEngine
        /// Listing the containers failed for another reason (the message).
        case failing(String)
        /// Enforcing; the number of containers that have a policy.
        case supervising(policies: Int)

        var logLine: String {
            switch self {
            case .starting: return "Starting."
            case .switchedOff: return "Restart policies are switched off in Settings. Idle."
            case .standingBy: return "Container Desktop is enforcing restart policies. Standing by."
            case .waitingForEngine: return "The container system is not running. Waiting for it."
            case .failing(let message): return "Could not list containers: \(message)"
            case .supervising(let count):
                return "Enforcing restart policies (\(count) container\(count == 1 ? "" : "s") with a policy)."
            }
        }
    }

    /// The outcome of the last pass.
    public private(set) var phase: Phase = .starting
    /// Passes made (for tests).
    public private(set) var passes = 0

    private let backend: SwitchableBackend
    private let supervisor: RestartSupervisor
    private let claim: EnforcementClaim
    private let isEnabled: @MainActor () -> Bool
    private let locateBackend: @MainActor () -> (any ContainerBackend)?
    private let cadence: Cadence
    private let scope: @MainActor (Container) -> Bool
    private let now: () -> Date
    private let log: @MainActor (String) -> Void
    private var engineWasDown = true
    private var failures = 0

    /// - Parameters:
    ///   - backend: what to list and start containers with (`UnavailableBackend` while the CLI is missing).
    ///   - state: the stops the app records (`FileSupervisionState` in the real helper).
    ///   - claim: the helper's claim on enforcement.
    ///   - isEnabled: the "Enforce restart policies" switch, read before every pass.
    ///   - locateBackend: called while the CLI is missing; returns a backend once it is installed.
    ///   - scope: which containers the helper may look at (all of them, except in tests on a real engine).
    ///   - cadence: how often to look.
    ///   - timing: the supervisor's backoff schedule.
    ///   - now: the clock (tests pass a fake one).
    ///   - log: one line per change of phase and per restart. Container names only, never their configuration.
    public init(
        backend: any ContainerBackend, state: any SupervisionStateStore, claim: EnforcementClaim,
        isEnabled: @escaping @MainActor () -> Bool = { true },
        locateBackend: @escaping @MainActor () -> (any ContainerBackend)? = { nil },
        scope: @escaping @MainActor (Container) -> Bool = { _ in true }, cadence: Cadence = Cadence(),
        timing: RestartSupervisor.Timing = RestartSupervisor.Timing(),
        now: @escaping () -> Date = { Date() }, log: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        let switchable = SwitchableBackend(backend)
        self.backend = switchable
        self.claim = claim
        self.isEnabled = isEnabled
        self.locateBackend = locateBackend
        self.cadence = cadence
        self.scope = scope
        self.now = now
        self.log = log
        supervisor = RestartSupervisor(
            isEnabled: isEnabled(), timing: timing, state: state, claim: { claim.hold() }, now: now
        ) { try await switchable.startContainer($0) }
        supervisor.onEvent = log
        supervisor.onGiveUp = { id, attempts in
            log("\(id) is not restarted again: it stopped after \(attempts) attempt(s), the limit of its policy.")
        }
    }

    /// The supervisor doing the work (for tests and diagnostics).
    public var restarts: RestartSupervisor { supervisor }

    /// Runs passes until the surrounding task is cancelled (SIGTERM), then lets go of the claim.
    public func run() async {
        log("Background supervision started.")
        while !Task.isCancelled {
            let delay = await step()
            do { try await Task.sleep(for: delay) } catch { break }
        }
        claim.release()
        log("Background supervision stopped.")
    }

    /// One pass. Returns how long to wait before the next one.
    public func step() async -> Duration {
        passes += 1
        supervisor.isEnabled = isEnabled()
        guard supervisor.isEnabled else {
            claim.release()
            enter(.switchedOff)
            return cadence.idle
        }
        guard claim.hold() else {
            enter(.standingBy)
            return cadence.active
        }
        do {
            let containers = try await backend.listContainers(includeStopped: true).filter(scope)
            failures = 0
            if engineWasDown { supervisor.engineCameUp() } else { supervisor.resume() }
            engineWasDown = false
            await supervisor.observe(containers)
            let policies = containers.filter { $0.restartPolicy.isEnforced }.count
            enter(.supervising(policies: policies))
            return wait(policies == 0 ? cadence.idle : cadence.active)
        } catch {
            return failed(BackendError(wrapping: error))
        }
    }

    /// `regular`, or less when a restart attempt is scheduled before that.
    private func wait(_ regular: Duration) -> Duration {
        guard let due = supervisor.earliestAttempt else { return regular }
        let untilDue = Duration.seconds(due.timeIntervalSince(now()))
        return min(regular, max(untilDue, cadence.minimum))
    }

    private func failed(_ error: BackendError) -> Duration {
        failures += 1
        supervisor.engineWentDown()
        switch error {
        case .systemNotRunning:
            engineWasDown = true
            enter(.waitingForEngine)
        case .cliNotInstalled:
            engineWasDown = true
            enter(.waitingForEngine)
            if let found = locateBackend() { backend.replace(with: found) }
        default:
            enter(.failing(error.errorDescription ?? "\(error)"))
        }
        return Poller.delay(base: cadence.active, failures: failures)
    }

    private func enter(_ next: Phase) {
        guard next != phase else { return }
        phase = next
        log(next.logLine)
    }
}
