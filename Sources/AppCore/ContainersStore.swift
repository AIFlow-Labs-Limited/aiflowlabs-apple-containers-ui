import Foundation
import Observation
import ContainerKit

/// Containers list, filters, live stats and lifecycle actions.
@MainActor
@Observable
public final class ContainersStore: PollingStore {
    /// How long a user-initiated stop stays "expected" if the container is never seen stopped.
    public static let expectedStopTTL: TimeInterval = 60

    public private(set) var items: [Container] = []
    public var isLoading = false
    public var loadError: BackendError?
    public var actionError: BackendError?
    /// Banner error: `actionError ?? loadError`. Setting `nil` clears both; a value becomes the `actionError`.
    public var lastError: BackendError? {
        get { actionError ?? loadError }
        set { actionError = newValue; if newValue == nil { loadError = nil } }
    }
    public var showStopped = true
    public var hideSystemManaged = true
    public var searchText = ""
    /// Latest stats sample per container id.
    public private(set) var stats: [String: ContainerStats] = [:]
    /// CPU % per container (100 = one core), from the last two samples.
    public private(set) var cpuPercent: [String: Double] = [:]
    /// Rolling 5-minute history per container, fed by every `refreshStats` (the Stats tab only renders it).
    public let statsHistory = ContainerStatsHistory(window: 300)
    /// Called when a container stops without the app having asked it to (crash notification).
    @ObservationIgnored public var onUnexpectedExit: (@MainActor (Container) -> Void)?
    /// Clock for expected-stop expiry (tests override it).
    @ObservationIgnored var now: () -> Date = { Date() }

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.loadError { throw error }
        await self.refreshStats()
    }
    @ObservationIgnored private let gate: PollingGate
    @ObservationIgnored private var lastSampleAt: Date?
    /// Ids the app is stopping/killing/restarting/deleting → when that was requested. An entry is dropped when the
    /// container is seen stopped (or gone), or after `expectedStopTTL` — never wholesale on a refresh, so a poll
    /// that lands while a slow stop is still in flight cannot turn it into an "exited unexpectedly" alert.
    @ObservationIgnored private var expectedStops: [String: Date] = [:]
    @ObservationIgnored private var hasLoadedOnce = false

    public init(backend: any ContainerBackend, gate: PollingGate) {
        self.backend = backend
        self.gate = gate
    }

    // MARK: Derived

    /// Items after the stopped/system/search filters.
    public var filtered: [Container] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return items.filter { c in
            (showStopped || c.isRunning)
                && (!hideSystemManaged || !c.isSystemManaged)
                && (q.isEmpty || c.id.localizedCaseInsensitiveContains(q) || c.imageReference.localizedCaseInsensitiveContains(q)
                    || (c.labels[AppLabel.project]?.localizedCaseInsensitiveContains(q) ?? false))
        }
    }

    public var runningCount: Int { items.count { $0.isRunning && !$0.isSystemManaged } }
    public var visibleCount: Int { items.count { !hideSystemManaged || !$0.isSystemManaged } }
    public var running: [Container] { items.filter { $0.isRunning && !$0.isSystemManaged } }
    /// Stopped containers the user owns (what "Prune" / "Clean up" remove; builder and k8s nodes excluded).
    public var prunable: [Container] { items.filter { !$0.isRunning && !$0.isSystemManaged } }
    public var totalCPUPercent: Double { cpuPercent.values.reduce(0, +) }
    public var totalMemoryBytes: Int64 { stats.values.reduce(0) { $0 + $1.memoryUsageBytes } }

    public func container(id: String) -> Container? { items.first { $0.id == id } }

    /// Whether `id` is currently in the expected-stop set (for tests/diagnostics).
    public func isExpectingStop(_ id: String) -> Bool { expectedStops[id] != nil }

    // MARK: Loading

    public func refresh() async {
        guard let list = await load({ try await backend.listContainers(includeStopped: true) }) else { return }
        detectUnexpectedExits(new: list)
        items = list.sorted { $0.configuration.creationDate > $1.configuration.creationDate }
        hasLoadedOnce = true
    }

    /// Samples stats for running containers, updates `cpuPercent` from the previous sample and appends to `statsHistory`.
    public func refreshStats(now date: Date = .now) async {
        let ids = items.filter(\.isRunning).map(\.id)
        guard !ids.isEmpty else { stats = [:]; cpuPercent = [:]; return }
        guard let samples = try? await backend.containerStats(ids: ids) else { return }
        var percent: [String: Double] = [:]
        if let last = lastSampleAt {
            let interval = date.timeIntervalSince(last)
            for sample in samples {
                if let previous = stats[sample.id] {
                    percent[sample.id] = ContainerStats.cpuPercent(previous: previous, current: sample, interval: interval)
                }
            }
        }
        for sample in samples { statsHistory.append(sample, at: date) }
        stats = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        cpuPercent = percent
        lastSampleAt = date
    }

    private func detectUnexpectedExits(new list: [Container]) {
        let current = now()
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        // Report first (an id seen stopped in this very refresh is still expected), then expire.
        if hasLoadedOnce, let onUnexpectedExit {
            let wasRunning = Set(items.filter(\.isRunning).map(\.id))
            for c in list where wasRunning.contains(c.id) && !c.isRunning && !isExpected(c.id, at: current) {
                onUnexpectedExit(c)
            }
        }
        for (id, since) in expectedStops {
            let seenStopped = byID[id].map { !$0.isRunning } ?? true
            if seenStopped || current.timeIntervalSince(since) > Self.expectedStopTTL { expectedStops[id] = nil }
        }
    }

    private func isExpected(_ id: String, at date: Date) -> Bool {
        guard let since = expectedStops[id] else { return false }
        return date.timeIntervalSince(since) <= Self.expectedStopTTL
    }

    private func expectStops(_ ids: [String]) {
        let date = now()
        for id in ids { expectedStops[id] = date }
    }

    // MARK: Actions

    @discardableResult
    public func start(_ ids: [String]) async -> BulkResult {
        await performEach(ids: ids) { try await backend.startContainer($0) }
    }

    @discardableResult
    public func stop(_ ids: [String], timeoutSeconds: Int? = nil) async -> BulkResult {
        expectStops(ids)
        return await performEach(ids: ids) { try await backend.stopContainer($0, timeoutSeconds: timeoutSeconds, signal: nil) }
    }

    @discardableResult
    public func kill(_ ids: [String], signal: String? = nil) async -> BulkResult {
        expectStops(ids)
        return await performEach(ids: ids) { try await backend.killContainer($0, signal: signal) }
    }

    /// Stop + start per id; a failure on one container does not skip the others.
    @discardableResult
    public func restart(_ ids: [String]) async -> BulkResult {
        expectStops(ids)
        let running = Set(items.filter(\.isRunning).map(\.id))
        return await performEach(ids: ids) { id in
            if running.contains(id) || container(id: id) == nil {
                try await backend.stopContainer(id, timeoutSeconds: nil, signal: nil)
            }
            statsHistory.reset(id)   // counters restart with the process
            try await backend.startContainer(id)
        }
    }

    /// Deletes each id. `force` only applies to containers that are running (a stopped container is always
    /// removed without `--force`), so "force" means "kill running ones and remove them".
    @discardableResult
    public func delete(_ ids: [String], force: Bool = false) async -> BulkResult {
        let running = Set(items.filter(\.isRunning).map(\.id))
        expectStops(ids.filter(running.contains))
        let result = await performEach(ids: ids) { id in
            try await backend.deleteContainer(id, force: force && running.contains(id))
        }
        for id in result.succeeded { statsHistory.reset(id) }
        return result
    }

    /// Removes stopped containers the user owns — explicitly by id, never `container prune`, so builder and
    /// Kubernetes node containers (`isSystemManaged`) are left alone.
    @discardableResult
    public func prune() async -> BulkResult {
        await delete(prunable.map(\.id), force: false)
    }
}
