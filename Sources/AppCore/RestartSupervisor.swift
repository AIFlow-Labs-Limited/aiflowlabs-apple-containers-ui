import ContainerKit
import Foundation
import Observation

/// Enforces restart policies, which Apple's runtime does not have.
///
/// The policy is the container's `AppLabel.restart` label. The supervisor has no timer of its own: the containers
/// poller hands it every fresh list (`observe`), and it starts what has to be started.
///
/// * A container with a policy that is found stopped, and was not stopped from this app, is started again:
///   after 1 s, then 2 s, 4 s … up to 60 s between attempts (`Timing`). The count starts over once the container
///   has stayed up for `Timing.stableAfter`.
/// * `on-failure:N` gives up after N attempts in a row; `always` and `unless-stopped` keep trying at the longest
///   delay.
/// * Stops made in the app (`noteStopRequested`) are remembered across relaunches, so those containers stay down.
/// * On the first list after a launch, after the engine came up, or after enforcement was switched on, stopped
///   `always` containers are started, and `unless-stopped` ones that were not stopped from the app.
/// * A container without a policy label is never touched.
///
/// Limits, by design: it only works while the app process lives, and a `container stop` typed in a terminal
/// cannot be told apart from a crash. The runtime reports no exit code (CLI 1.5.0), so `on-failure` restarts on
/// any unexpected stop unless `exitCode` can supply one.
@MainActor
@Observable
public final class RestartSupervisor {
    /// The backoff schedule.
    public struct Timing: Sendable, Equatable {
        /// Delay before the first restart attempt.
        public var initialDelay: TimeInterval = 1
        /// Longest delay between two attempts.
        public var maxDelay: TimeInterval = 60
        /// Uptime after which a container counts as healthy again and the attempt count starts over.
        public var stableAfter: TimeInterval = 30

        /// 1 s doubling to 60 s, reset after 30 s of uptime.
        public init() {}

        /// Delay before attempt number `attempt` (1-based): `initialDelay × 2^(attempt − 1)`, capped at `maxDelay`.
        public func delay(beforeAttempt attempt: Int) -> TimeInterval {
            min(initialDelay * pow(2, Double(max(0, min(attempt, 32) - 1))), maxDelay)
        }
    }

    /// What the supervisor knows about one container, for the inspector.
    public struct Status: Equatable, Sendable {
        /// Restarts since the app was launched.
        public var restartCount = 0
        /// Attempts in a row without the container staying up for `Timing.stableAfter`.
        public var consecutiveAttempts = 0
        /// When the next attempt is due, while one is scheduled.
        public var nextAttempt: Date?
        /// `on-failure:N` reached its limit; nothing more happens until the container is started by hand.
        public var gaveUp = false

        /// Nothing has happened yet.
        public init() {}
    }

    private struct Record {
        var status = Status()
        /// The supervisor started it and has not seen it running since.
        var awaitingResult = false
        /// It was running the last time it was looked at.
        var sawRunning = false
        /// `startedDate` of the run whose end has been dealt with.
        var handledStart: Date?
        /// When it was first seen running in its current run (fallback when the runtime gives no start date).
        var firstSeenRunning: Date?
    }

    /// UserDefaults key of the ids stopped from the app (id → time of the stop).
    public static let intentionalStopsKey = "restartPolicy.intentionalStops"

    /// Global switch (Settings → General). Switching it on behaves like a launch.
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            records = [:]
            launchPassPending = true
        }
    }
    public var timing: Timing

    /// Called when `on-failure:N` gives up on a container (id, attempts made).
    @ObservationIgnored public var onGiveUp: (@MainActor (_ id: String, _ attempts: Int) -> Void)?

    private var records: [String: Record] = [:]
    private var intentionalStops: [String: Date]
    @ObservationIgnored private var launchPassPending = true
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let taskCenter: TaskCenter?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let exitCode: (Container) -> Int32?
    @ObservationIgnored private let start: @MainActor (String) async throws -> Void

    /// - Parameters:
    ///   - defaults: where the "stopped from the app" set is kept.
    ///   - taskCenter: gets one finished entry per restart (Activity panel, toast). `nil` in tests that do not care.
    ///   - now: the clock (tests pass a fake one).
    ///   - exitCode: the exit code of a stopped container when the runtime reports one. CLI 1.5.0 does not, hence
    ///     the default.
    ///   - start: starts a container through the backend.
    public init(
        isEnabled: Bool = true, timing: Timing = Timing(), defaults: UserDefaults = .standard,
        taskCenter: TaskCenter? = nil, now: @escaping () -> Date = { Date() },
        exitCode: @escaping (Container) -> Int32? = { _ in nil },
        start: @escaping @MainActor (String) async throws -> Void
    ) {
        self.isEnabled = isEnabled
        self.timing = timing
        self.defaults = defaults
        self.taskCenter = taskCenter
        self.now = now
        self.exitCode = exitCode
        self.start = start
        let stored = defaults.dictionary(forKey: Self.intentionalStopsKey) as? [String: Double] ?? [:]
        intentionalStops = stored.mapValues { Date(timeIntervalSince1970: $0) }
    }

    // MARK: What the app tells the supervisor

    /// The user stopped, killed or deleted these containers in the app: they are not restarted.
    public func noteStopRequested(_ ids: [String]) {
        let date = now()
        for id in ids { intentionalStops[id] = date }
        persist()
    }

    /// The user started these containers in the app: they are supervised again.
    public func noteStartRequested(_ ids: [String]) {
        for id in ids {
            intentionalStops[id] = nil
            records[id]?.status.gaveUp = false
            records[id]?.status.consecutiveAttempts = 0
            records[id]?.status.nextAttempt = nil
        }
        persist()
    }

    /// The engine is being stopped from the app: its containers stopping is not a crash.
    public func engineWillStop() { suspended = true }

    /// The engine is running (again): the next list is treated like the first one after a launch.
    public func engineCameUp() {
        suspended = false
        launchPassPending = true
    }

    /// The engine cannot be asked right now (stopped, starting, or its status could not be read).
    public func engineWentDown() { suspended = true }

    /// The engine answers again without having been down (a failed stop, a status hiccup): carry on, without
    /// the launch treatment.
    public func resume() { suspended = false }

    // MARK: What the UI asks

    public func status(for id: String) -> Status? { records[id]?.status }
    public func isIntentionallyStopped(_ id: String) -> Bool { intentionalStops[id] != nil }
    /// Restarts made since launch, over all containers.
    public var totalRestarts: Int { records.values.reduce(0) { $0 + $1.status.restartCount } }

    // MARK: Supervision

    /// Looks at a fresh container list and starts what its policy says must run.
    ///
    /// - Parameter busy: ids with an app action in flight (stopping, deleting, …); they are skipped this time.
    public func observe(_ containers: [Container], busy: Set<String> = []) async {
        guard isEnabled, !suspended, !isObserving else { return }
        isObserving = true
        defer { isObserving = false }
        let launch = launchPassPending
        launchPassPending = false
        forget(allExcept: Set(containers.map(\.id)))
        for container in containers {
            guard !suspended, isEnabled else { return }
            let policy = container.restartPolicy
            guard policy.isEnforced else {
                records[container.id] = nil
                continue
            }
            if busy.contains(container.id) { continue }
            if container.isRunning {
                sawRunning(container)
            } else if launch {
                await launchPass(container, policy: policy)
            } else {
                await sawStopped(container, policy: policy)
            }
        }
    }

    private func sawRunning(_ container: Container) {
        let current = now()
        var record = records[container.id] ?? Record()
        let started = container.status?.startedDate
        // A stop mark older than this run is spent: someone started the container since.
        if let mark = intentionalStops[container.id], started.map({ $0 > mark }) ?? true {
            intentionalStops[container.id] = nil
            persist()
        }
        if !record.sawRunning { record.firstSeenRunning = current }
        record.sawRunning = true
        record.awaitingResult = false
        record.status.nextAttempt = nil
        let since = started ?? record.firstSeenRunning ?? current
        if current.timeIntervalSince(since) >= timing.stableAfter {
            record.status.consecutiveAttempts = 0
            record.status.gaveUp = false
        }
        records[container.id] = record
    }

    /// First look after a launch, an engine start or switching enforcement on.
    private func launchPass(_ container: Container, policy: RestartPolicy) async {
        let id = container.id
        dropStaleMark(container)
        var record = Record()
        record.status.restartCount = records[id]?.status.restartCount ?? 0
        record.handledStart = container.status?.startedDate
        records[id] = record
        guard policy.startsOnLaunch(intentionallyStopped: intentionalStops[id] != nil) else { return }
        // `always` comes back on launch even after a stop from the app, as in Docker.
        if intentionalStops[id] != nil {
            intentionalStops[id] = nil
            persist()
        }
        let title = "Start \(id) (restart policy \(policy.rawValue))"
        let why = "\(id) has the restart policy “\(policy.rawValue)” and was stopped. Starting it."
        if await attemptStart(id, title: title, explanation: why) { records[id]?.awaitingResult = true }
    }

    private func sawStopped(_ container: Container, policy: RestartPolicy) async {
        let id = container.id
        let current = now()
        dropStaleMark(container)
        var record = records[id] ?? Record()
        let started = container.status?.startedDate
        if intentionalStops[id] != nil {
            // Stopped from the app: stays down until it is started again (or, for `always`, the next launch).
            record.handledStart = started
            record.sawRunning = false
            record.awaitingResult = false
            record.status.nextAttempt = nil
            record.status.consecutiveAttempts = 0
            records[id] = record
            return
        }
        // It ran and ended since the last look: seen running, started by us, or a start date not dealt with yet.
        let exited = record.sawRunning || record.awaitingResult || (started != nil && started != record.handledStart)
        if exited {
            record.sawRunning = false
            record.awaitingResult = false
            record.handledStart = started
            record.status.nextAttempt = nil
            if case .onFailure(let limit) = policy {
                if exitCode(container) == 0 {
                    record.status.consecutiveAttempts = 0
                    records[id] = record
                    return
                }
                if let limit, record.status.consecutiveAttempts >= limit {
                    giveUp(id, record: &record)
                    return
                }
            }
            record.status.gaveUp = false
            let delay = timing.delay(beforeAttempt: record.status.consecutiveAttempts + 1)
            record.status.nextAttempt = current.addingTimeInterval(delay)
        }
        guard let due = record.status.nextAttempt, current >= due else {
            records[id] = record
            return
        }
        record.status.nextAttempt = nil
        record.status.consecutiveAttempts += 1
        let attempt = record.status.consecutiveAttempts
        records[id] = record
        let code = exitCode(container).map { " (exit \($0))" } ?? ""
        let title = "Restart \(id)\(code), attempt \(attempt)"
        let why = "\(id) stopped\(code) and has the restart policy “\(policy.rawValue)”. Starting it again."
        if await attemptStart(id, title: title, explanation: why) {
            records[id]?.status.restartCount += 1
            records[id]?.awaitingResult = true
            return
        }
        guard var failed = records[id], !suspended else {
            // The engine went away under us: this was not an attempt.
            records[id]?.status.consecutiveAttempts = attempt - 1
            records[id]?.status.nextAttempt = due
            return
        }
        if case .onFailure(let limit?) = policy, attempt >= limit {
            giveUp(id, record: &failed)
            return
        }
        failed.status.nextAttempt = now().addingTimeInterval(timing.delay(beforeAttempt: attempt + 1))
        records[id] = failed
    }

    private func giveUp(_ id: String, record: inout Record) {
        let alreadyTold = record.status.gaveUp
        record.status.gaveUp = true
        record.status.nextAttempt = nil
        records[id] = record
        if !alreadyTold { onGiveUp?(id, record.status.consecutiveAttempts) }
    }

    /// Starts `id` and records the outcome in the Activity panel. Returns whether it started.
    private func attemptStart(_ id: String, title: String, explanation: String) async -> Bool {
        do {
            try await start(id)
            announce(title, lines: [explanation, "\(id) is running."], failure: nil)
            return true
        } catch {
            let wrapped = BackendError(wrapping: error)
            if wrapped == .systemNotRunning {
                suspended = true  // until `engineCameUp()`
            } else {
                announce(title, lines: [explanation], failure: wrapped)
            }
            return false
        }
    }

    private func announce(_ title: String, lines: [String], failure: BackendError?) {
        guard let taskCenter else { return }
        let stream = LineStream { continuation in
            for line in lines { continuation.yield(OutputLine(line)) }
            continuation.finish(throwing: failure)
        }
        taskCenter.run(title: title, kind: .run, stream: stream)
    }

    /// A stop mark made before the container was created belongs to an earlier container of the same name.
    private func dropStaleMark(_ container: Container) {
        guard let mark = intentionalStops[container.id], container.configuration.creationDate > mark else { return }
        intentionalStops[container.id] = nil
        persist()
    }

    private func forget(allExcept present: Set<String>) {
        records = records.filter { present.contains($0.key) }
        let kept = intentionalStops.filter { present.contains($0.key) }
        if kept.count != intentionalStops.count {
            intentionalStops = kept
            persist()
        }
    }

    private func persist() {
        defaults.set(intentionalStops.mapValues(\.timeIntervalSince1970), forKey: Self.intentionalStopsKey)
    }
}
