import Foundation
import Observation
import ContainerKit

/// Compose-style group of containers sharing `AppLabel.project` (`nil` project = ungrouped).
public struct ContainerGroup: Identifiable, Hashable, Sendable {
    public var project: String?
    public var containers: [Container]
    public var id: String { project ?? "" }
    public var title: String { project ?? "Other containers" }
    public var runningCount: Int { containers.count(where: \.isRunning) }
}

/// Containers list, filters, live stats and lifecycle actions.
@MainActor
@Observable
public final class ContainersStore: PollingStore {
    public private(set) var items: [Container] = []
    public var isLoading = false
    public var lastError: BackendError?
    public var showStopped = true
    public var hideSystemManaged = true
    public var searchText = ""
    /// Latest stats sample per container id.
    public private(set) var stats: [String: ContainerStats] = [:]
    /// CPU % per container (100 = one core), from the last two samples.
    public private(set) var cpuPercent: [String: Double] = [:]
    /// Called when a container stops without the app having asked it to (crash notification).
    @ObservationIgnored public var onUnexpectedExit: (@MainActor (Container) -> Void)?

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.lastError { throw error }
        await self.refreshStats()
    }
    @ObservationIgnored private let gate: PollingGate
    @ObservationIgnored private var lastSampleAt: Date?
    @ObservationIgnored private var expectedStops: Set<String> = []
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

    /// `filtered` grouped by compose project; projects first (sorted), ungrouped last.
    public var groupedByProject: [ContainerGroup] {
        let groups = Dictionary(grouping: filtered) { $0.labels[AppLabel.project] }
        let named = groups.compactMap { key, value in key.map { ContainerGroup(project: $0, containers: value) } }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let loose = groups[nil].map { [ContainerGroup(project: nil, containers: $0)] } ?? []
        return named + loose
    }

    public var runningCount: Int { items.count { $0.isRunning && !$0.isSystemManaged } }
    public var visibleCount: Int { items.count { !hideSystemManaged || !$0.isSystemManaged } }
    public var running: [Container] { items.filter { $0.isRunning && !$0.isSystemManaged } }
    public var totalCPUPercent: Double { cpuPercent.values.reduce(0, +) }
    public var totalMemoryBytes: Int64 { stats.values.reduce(0) { $0 + $1.memoryUsageBytes } }

    public func container(id: String) -> Container? { items.first { $0.id == id } }

    // MARK: Loading

    public func refresh() async {
        guard let list = await load({ try await backend.listContainers(includeStopped: true) }) else { return }
        detectUnexpectedExits(new: list)
        items = list.sorted { $0.configuration.creationDate > $1.configuration.creationDate }
        hasLoadedOnce = true
    }

    /// Samples stats for running containers and updates `cpuPercent` from the previous sample.
    public func refreshStats(now: Date = .now) async {
        let ids = items.filter(\.isRunning).map(\.id)
        guard !ids.isEmpty else { stats = [:]; cpuPercent = [:]; return }
        guard let samples = try? await backend.containerStats(ids: ids) else { return }
        var percent: [String: Double] = [:]
        if let last = lastSampleAt {
            let interval = now.timeIntervalSince(last)
            for sample in samples {
                if let previous = stats[sample.id] {
                    percent[sample.id] = ContainerStats.cpuPercent(previous: previous, current: sample, interval: interval)
                }
            }
        }
        stats = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        cpuPercent = percent
        lastSampleAt = now
    }

    private func detectUnexpectedExits(new list: [Container]) {
        defer { expectedStops.removeAll() }
        guard hasLoadedOnce, let onUnexpectedExit else { return }
        let wasRunning = Set(items.filter(\.isRunning).map(\.id))
        for c in list where wasRunning.contains(c.id) && !c.isRunning && !expectedStops.contains(c.id) {
            onUnexpectedExit(c)
        }
    }

    // MARK: Actions

    public func start(_ ids: [String]) async {
        await perform { for id in ids { try await backend.startContainer(id) } }
    }

    public func stop(_ ids: [String], timeoutSeconds: Int? = nil) async {
        expectedStops.formUnion(ids)
        await perform { for id in ids { try await backend.stopContainer(id, timeoutSeconds: timeoutSeconds, signal: nil) } }
    }

    public func kill(_ ids: [String], signal: String? = nil) async {
        expectedStops.formUnion(ids)
        await perform { for id in ids { try await backend.killContainer(id, signal: signal) } }
    }

    public func restart(_ ids: [String]) async {
        expectedStops.formUnion(ids)
        await perform {
            for id in ids {
                try await backend.stopContainer(id, timeoutSeconds: nil, signal: nil)
                try await backend.startContainer(id)
            }
        }
    }

    public func delete(_ ids: [String], force: Bool = false) async {
        expectedStops.formUnion(ids)
        await perform { for id in ids { try await backend.deleteContainer(id, force: force) } }
    }

    /// Removes all stopped containers.
    public func prune() async { await perform { try await backend.pruneContainers() } }
}
