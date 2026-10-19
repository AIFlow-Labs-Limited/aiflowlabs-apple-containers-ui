import Foundation
import Observation
import ContainerKit
import AppCore

/// Tabs of the container detail pane (Docker Desktop order).
enum ContainerDetailTab: String, CaseIterable, Identifiable, Codable {
    case logs, inspect, terminal, stats, mounts, ports, environment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logs: return "Logs"
        case .inspect: return "Inspect"
        case .terminal: return "Terminal"
        case .stats: return "Stats"
        case .mounts: return "Mounts"
        case .ports: return "Ports"
        case .environment: return "Environment"
        }
    }

    var symbol: String {
        switch self {
        case .logs: return "text.alignleft"
        case .inspect: return "info.circle"
        case .terminal: return "terminal"
        case .stats: return "chart.xyaxis.line"
        case .mounts: return "externaldrive"
        case .ports: return "point.3.connected.trianglepath.dotted"
        case .environment: return "list.bullet.rectangle"
        }
    }
}

/// Presents the Run sheet, optionally prefilled (from an image, a deep link, or "Run similar").
struct RunSheetRequest: Identifiable {
    let id = UUID()
    var spec: RunSpec?
}

/// View state shared by the containers list, toolbar, context menus and detail pane.
@MainActor
@Observable
final class ContainersUIState {
    var selection = Set<String>()
    /// Container ids awaiting delete / kill confirmation.
    var pendingDelete: [String] = []
    var pendingKill: [String] = []
    var runRequest: RunSheetRequest?
    /// Detail pane visible for a single selection (Return re-opens it after "Hide details").
    var showDetail = true
    /// Project groups the user collapsed.
    var collapsedProjects = Set<String>()
    var sortOrder: [KeyPathComparator<ContainerRow>] = [KeyPathComparator(\ContainerRow.name)]
    /// 5-minute stats history per container, kept while the Containers section is open.
    let statsHistory = ContainerStatsHistory(window: 300)
    /// Per-container selected tab, persisted across launches.
    private(set) var tabs: [String: ContainerDetailTab]

    @ObservationIgnored private let defaults: UserDefaults
    private static let tabsKey = "containers.detailTabs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.tabsKey),
           let decoded = try? JSONDecoder().decode([String: ContainerDetailTab].self, from: data) {
            tabs = decoded
        } else {
            tabs = [:]
        }
    }

    func tab(for id: String) -> ContainerDetailTab { tabs[id] ?? .logs }

    func setTab(_ tab: ContainerDetailTab, for id: String) {
        guard tabs[id] != tab else { return }
        tabs[id] = tab
        // Keep the dictionary small: forget the oldest entries beyond 200 containers.
        if tabs.count > 200, let victim = tabs.keys.sorted().first { tabs[victim] = nil }
        if let data = try? JSONEncoder().encode(tabs) { defaults.set(data, forKey: Self.tabsKey) }
    }

    /// Selects `id` and switches its detail pane to `tab`.
    func open(_ id: String, tab: ContainerDetailTab) {
        selection = [id]
        showDetail = true
        setTab(tab, for: id)
    }
}
