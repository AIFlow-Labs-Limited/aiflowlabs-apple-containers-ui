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
/// The same class runs in the app and in the background helper (`BackgroundSupervisor`). Only one of them acts:
/// before every pass it asks `claim` whether it is the enforcer, and stands down when it is not. What the user
/// asked for (stops, an engine stop) lives in a `SupervisionStateStore` both read, so a stop made in the app is
/// respected by the helper.
///
/// Limits, by design: it only works while the app or the helper lives, and a `container stop` typed in a
/// terminal cannot be told apart from a crash. The runtime reports no exit code (CLI 1.5.0), so `on-failure`
/// restarts on any unexpected stop unless `exitCode` can supply one.
@MainActor
@Observable
public final class RestartSupervisor {
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

    /// UserDefaults key of the ids stopped from the app (id → time of the stop), when the state is kept there.
    public static let intentionalStopsKey = DefaultsSupervisionState.stopsKey
    /// How long an engine stop asked for in the app keeps every supervisor quiet when the engine is never seen
    /// down (the stop failed, or the engine was started again before anyone looked).
    public static let engineStopGrace: TimeInterval = 120

    /// Global switch (Settings → General). Switching it on behaves like a launch.
    public var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            records = [:]
            launchPassPending = true
        }
    }
    public var timing: Timing
    /// Another process (the background helper, or the app) is the enforcer; this supervisor only records what the
    /// user asks for.
    public private(set) var isStandingDown = false

    /// Called when `on-failure:N` gives up on a container (id, attempts made).
    @ObservationIgnored public var onGiveUp: (@MainActor (_ id: String, _ attempts: Int) -> Void)?
    /// One line per restart attempt and its outcome (the helper's log). Container names only.
    @ObservationIgnored public var onEvent: (@MainActor (String) -> Void)?

    private var records: [String: Record] = [:]
    private var intentionalStops: [String: Date]
    @ObservationIgnored private var launchPassPending = true
    @ObservationIgnored private var suspended = false
    @ObservationIgnored private var isObserving = false
    /// When the previous pass began. Every list handed over since is newer than that.
    @ObservationIgnored private var previousPass: Date?
    @ObservationIgnored private let store: any SupervisionStateStore
    @ObservationIgnored private let claim: @MainActor () -> Bool
    @ObservationIgnored private let taskCenter: TaskCenter?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let exitCode: (Container) -> Int32?
    @ObservationIgnored private let start: @MainActor (String) async throws -> Void

    /// - Parameters:
    ///   - defaults: where the "stopped from the app" set is kept when `state` is `nil`.
    ///   - state: the shared record of what the user asked for (a file when a helper may be running).
    ///   - claim: whether this process is the enforcer right now; asked before every pass.
    ///   - taskCenter: gets one finished entry per restart (Activity panel, toast). `nil` in tests that do not care.
    ///   - now: the clock (tests pass a fake one).
    ///   - exitCode: the exit code of a stopped container when the runtime reports one. CLI 1.5.0 does not, hence
    ///     the default.
    ///   - start: starts a container through the backend.
    public init(
        isEnabled: Bool = true, timing: Timing = Timing(), defaults: UserDefaults = .standard,
        state: (any SupervisionStateStore)? = nil, claim: @escaping @MainActor () -> Bool = { true },
        taskCenter: TaskCenter? = nil, now: @escaping () -> Date = { Date() },
        exitCode: @escaping (Container) -> Int32? = { _ in nil },
        start: @escaping @MainActor (String) async throws -> Void
    ) {
        self.isEnabled = isEnabled
        self.timing = timing
        let store = state ?? DefaultsSupervisionState(defaults)
        self.store = store
        self.claim = claim
        self.taskCenter = taskCenter
        self.now = now
        self.exitCode = exitCode
        self.start = start
        intentionalStops = store.read().stops
    }

    // MARK: What the app tells the supervisor

    /// The user stopped, killed or deleted these containers in the app: they are not restarted.
    public func noteStopRequested(_ ids: [String]) {
        let date = now()
        updateMarks { marks in for id in ids { marks[id] = date } }
    }

    /// The user started these containers in the app: they are supervised again.
    public func noteStartRequested(_ ids: [String]) {
        for id in ids {
            records[id]?.status.gaveUp = false
            records[id]?.status.consecutiveAttempts = 0
            records[id]?.status.nextAttempt = nil
        }
        updateMarks { marks in for id in ids { marks[id] = nil } }
    }

    /// The engine is being stopped from the app: its containers stopping is not a crash.
    /// Recorded in the shared state too, so a helper that enforces does not fight the shutdown.
    public func engineWillStop() {
        suspended = true
        let date = now()
        store.update { $0.engineStopRequested = date }
    }

    /// The engine stop asked for with `engineWillStop()` failed: the engine is still up, carry on.
    public func engineStopFailed() {
        suspended = false
        clearEngineStop()
    }

    /// The engine is running (again): the next list is treated like the first one after a launch.
    public func engineCameUp() {
        suspended = false
        launchPassPending = true
        clearEngineStop()
    }

    /// The engine cannot be asked right now (stopped, starting, or its status could not be read).
    public func engineWentDown() { suspended = true }

    /// The engine answers again without having been down (a failed stop, a status hiccup): carry on, without
    /// the launch treatment.
    public func resume() { suspended = false }

    // MARK: What the UI asks

    public func status(for id: String) -> Status? { records[id]?.status }
    public func isIntentionallyStopped(_ id: String) -> Bool { intentionalStops[id] != nil }
    /// When the next scheduled restart attempt is due, if any (the helper wakes up for it).
    public var earliestAttempt: Date? { records.values.compactMap(\.status.nextAttempt).min() }
    /// Restarts made since launch, over all containers.
    public var totalRestarts: Int { records.values.reduce(0) { $0 + $1.status.restartCount } }

    // MARK: Supervision

    /// Looks at a fresh container list and starts what its policy says must run.
    ///
    /// - Parameter busy: ids with an app action in flight (stopping, deleting, …); they are skipped this time.
    public func observe(_ containers: [Container], busy: Set<String> = []) async {
        guard isEnabled, !isObserving else { return }
        let shared = store.read()
        if shared.stops != intentionalStops { intentionalStops = shared.stops }
        guard claimEnforcement(), !suspended, !engineStopPending(shared) else { return }
        isObserving = true
        defer { isObserving = false }
        let launch = launchPassPending
        launchPassPending = false
        forget(allExcept: Set(containers.map(\.id)), marksUpTo: previousPass)
        previousPass = now()
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

    /// Asks `claim` and handles the change of hands in either direction.
    private func claimEnforcement() -> Bool {
        guard claim() else {
            if !isStandingDown {
                isStandingDown = true
                records = [:]
            }
            return false
        }
        if isStandingDown {
            // Taking over from another enforcer is not a launch: what the user stopped stays stopped, also with
            // `always`. A container found stopped is handled as "it ended since anyone last looked".
            isStandingDown = false
            records = [:]
            launchPassPending = false
        }
        return true
    }

    private func engineStopPending(_ shared: SupervisionState) -> Bool {
        guard let requested = shared.engineStopRequested else { return false }
        return now().timeIntervalSince(requested) < Self.engineStopGrace
    }

    private func clearEngineStop() {
        guard store.read().engineStopRequested != nil else { return }
        store.update { $0.engineStopRequested = nil }
    }

    private func sawRunning(_ container: Container) {
        let current = now()
        var record = records[container.id] ?? Record()
        let started = container.status?.startedDate
        // A stop mark older than this run is spent: someone started the container since. Without a start date
        // the mark is kept while the stop it announces may still be on its way (the enforcer can be another
        // process than the one stopping the container).
        if let mark = intentionalStops[container.id],
            started.map({ $0 > mark }) ?? (current.timeIntervalSince(mark) > ContainersStore.expectedStopTTL)
        {
            clearMark(container.id)
        }
        if record.status.gaveUp {
            // Nothing starts a container the supervisor gave up on, so someone did it by hand: begin again.
            record.status.gaveUp = false
            record.status.consecutiveAttempts = 0
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
        if intentionalStops[id] != nil { clearMark(id) }
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
        onEvent?(failure.map { "\(title): failed. \($0.errorDescription ?? "\($0)")" } ?? title)
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
        clearMark(container.id)
    }

    /// Drops what is known about containers that no longer exist. A stop mark goes only when it is older than
    /// the previous pass: a younger one may belong to a container created after this list was taken (the app
    /// records stops while another process enforces).
    private func forget(allExcept present: Set<String>, marksUpTo limit: Date?) {
        records = records.filter { present.contains($0.key) }
        guard let limit else { return }
        let gone = intentionalStops.filter { !present.contains($0.key) && $0.value <= limit }
        guard !gone.isEmpty else { return }
        // Only marks that are still the ones looked at: a newer one was made since and stays.
        updateMarks { marks in for (id, date) in gone where marks[id] == date { marks[id] = nil } }
    }

    private func clearMark(_ id: String) {
        let seen = intentionalStops[id]
        updateMarks { marks in if marks[id] == seen { marks[id] = nil } }
    }

    /// Changes the shared stop marks and takes over the result.
    private func updateMarks(_ change: (inout [String: Date]) -> Void) {
        let updated = store.update { change(&$0.stops) }
        if updated.stops != intentionalStops { intentionalStops = updated.stops }
    }
}
