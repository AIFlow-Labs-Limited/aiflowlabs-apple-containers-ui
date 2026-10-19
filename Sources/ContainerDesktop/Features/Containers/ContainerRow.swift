import Foundation
import ContainerKit
import AppCore
import DesignSystem

/// One table row: a container, or a compose-style project group whose children are containers.
/// Flat sortable fields so `KeyPathComparator` works for every column.
struct ContainerRow: Identifiable, Hashable {
    static let projectPrefix = "project:"

    let id: String
    let name: String
    let imageShort: String
    let imageFull: String
    let state: ContainerState
    let statusText: String
    /// running < created/stopping < exited < unknown, so ascending sort puts running first.
    let statusRank: Int
    /// CPU % (100 = one core); -1 when unknown (stopped / first sample).
    let cpu: Double
    let memory: Int64
    let memoryLimit: Int64
    let ports: [Container.PublishedPort]
    let portsSort: Int
    let ip: String
    let started: Date
    let hasStarted: Bool
    let container: Container?
    /// Containers of a project row (empty for container rows).
    let members: [Container]
    var children: [ContainerRow]?

    var isProject: Bool { container == nil }
    var projectName: String? { isProject ? String(id.dropFirst(Self.projectPrefix.count)) : nil }
    var memberIDs: [String] { container.map { [$0.id] } ?? members.map(\.id) }

    init(container c: Container, stats: ContainerStats?, cpu: Double?, now: Date = .now) {
        id = c.id
        name = c.id
        imageFull = c.imageReference
        imageShort = Self.shortImage(c.imageReference)
        state = c.state
        if c.isRunning, let startedDate = c.status?.startedDate {
            statusText = "Running · \(RelativeDate.uptime(since: startedDate, now: now))"
        } else {
            statusText = c.state.displayName
        }
        statusRank = Self.rank(c.state)
        self.cpu = c.isRunning ? (cpu ?? -1) : -1
        memory = c.isRunning ? (stats?.memoryUsageBytes ?? 0) : 0
        memoryLimit = stats?.memoryLimitBytes ?? c.configuration.resources.memoryInBytes
        ports = c.configuration.publishedPorts
        portsSort = c.configuration.publishedPorts.map(\.hostPort).min() ?? .max
        ip = c.primaryIPv4 ?? ""
        started = c.status?.startedDate ?? .distantPast
        hasStarted = c.isRunning && c.status?.startedDate != nil
        container = c
        members = []
        children = nil
    }

    init(project: String, children rows: [ContainerRow]) {
        id = Self.projectPrefix + project
        name = project
        let running = rows.count { $0.state == .running }
        imageShort = rows.count == 1 ? "1 container" : "\(rows.count) containers"
        imageFull = rows.map(\.imageFull).joined(separator: "\n")
        state = running > 0 ? .running : .stopped
        statusText = running == rows.count ? "Running (\(running))" : "\(running)/\(rows.count) running"
        statusRank = running > 0 ? 0 : 2
        let cpus = rows.map(\.cpu).filter { $0 >= 0 }
        cpu = cpus.isEmpty ? -1 : cpus.reduce(0, +)
        memory = rows.reduce(0) { $0 + $1.memory }
        memoryLimit = rows.reduce(0) { $0 + $1.memoryLimit }
        ports = rows.flatMap(\.ports)
        portsSort = rows.map(\.portsSort).min() ?? .max
        ip = ""
        started = rows.filter(\.hasStarted).map(\.started).min() ?? .distantPast
        hasStarted = rows.contains(where: \.hasStarted)
        container = nil
        members = rows.compactMap(\.container)
        children = rows
    }

    static func rank(_ state: ContainerState) -> Int {
        switch state {
        case .running: return 0
        case .created, .stopping: return 1
        case .stopped: return 2
        case .unknown: return 3
        }
    }

    /// `docker.io/library/postgres:16-alpine` → `postgres:16-alpine`; digests are dropped.
    static func shortImage(_ reference: String) -> String {
        var ref = reference
        if let at = ref.firstIndex(of: "@") { ref = String(ref[..<at]) }
        for prefix in ["docker.io/library/", "docker.io/"] where ref.hasPrefix(prefix) {
            ref = String(ref.dropFirst(prefix.count))
            break
        }
        return ref
    }

    /// Builds the visible rows: flat, or grouped by `AppLabel.project` (projects first), each level sorted.
    @MainActor static func build(store: ContainersStore, grouped: Bool, sortOrder: [KeyPathComparator<ContainerRow>],
                      now: Date = .now) -> [ContainerRow] {
        let rows = store.filtered.map { ContainerRow(container: $0, stats: store.stats[$0.id], cpu: store.cpuPercent[$0.id], now: now) }
        guard grouped else { return rows.sorted(using: sortOrder) }
        let byProject = Dictionary(grouping: rows) { $0.container?.labels[AppLabel.project] }
        let projects = byProject.compactMap { key, value in
            key.map { ContainerRow(project: $0, children: value.sorted(using: sortOrder)) }
        }
        let loose = byProject[nil] ?? []
        return projects.sorted(using: sortOrder) + loose.sorted(using: sortOrder)
    }
}

@MainActor
extension ContainersStore {
    /// Expands project row ids (`project:<name>`) into their container ids; plain ids pass through.
    func containerIDs(for ids: some Sequence<String>) -> [String] {
        var result: [String] = []
        for id in ids {
            if id.hasPrefix(ContainerRow.projectPrefix) {
                let project = String(id.dropFirst(ContainerRow.projectPrefix.count))
                result += filtered.filter { $0.labels[AppLabel.project] == project }.map(\.id)
            } else {
                result.append(id)
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}
