import AppCore
import ContainerKit
import Foundation
import Observation

/// Tabs of the container detail pane (Docker Desktop order).
enum ContainerDetailTab: String, CaseIterable, Identifiable, Codable {
    case logs, inspect, terminal, files, stats, mounts, ports, environment

    var id: String { rawValue }

    var title: String {
        switch self {
        case .logs: return "Logs"
        case .inspect: return "Inspect"
        case .terminal: return "Terminal"
        case .files: return "Files"
        case .stats: return "Stats"
        case .mounts: return "Mounts"
        case .ports: return "Ports"
        case .environment: return "Environment"
        }
    }
}

/// Presents the Run sheet, optionally prefilled (from an image, a deep link, or "Run similar").
struct RunSheetRequest: Identifiable {
    let id = UUID()
    var spec: RunSpec?
}

/// Presents the "Save as Image…" sheet for one container.
struct CommitSheetRequest: Identifiable {
    let id = UUID()
    let container: Container
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
    var commitRequest: CommitSheetRequest?
    /// Whether the runtime has `container commit` (1.6+); `nil` until probed.
    private(set) var commitSupported: Bool?
    /// Files tab state per container, so switching tabs keeps the folder that was open.
    @ObservationIgnored private var filesModels: [String: ContainerFilesModel] = [:]
    /// Detail pane visible for a single selection (Return re-opens it after "Hide details").
    var showDetail = true
    /// Project groups the user collapsed.
    var collapsedProjects = Set<String>()
    var sortOrder: [KeyPathComparator<ContainerRow>] = [KeyPathComparator(\ContainerRow.name)]
    /// Per-container selected tab, persisted across launches.
    private(set) var tabs: [String: ContainerDetailTab]

    @ObservationIgnored private let defaults: UserDefaults
    private static let tabsKey = "containers.detailTabs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.tabsKey),
            let decoded = try? JSONDecoder().decode([String: ContainerDetailTab].self, from: data)
        {
            tabs = decoded
        } else {
            tabs = [:]
        }
    }

    func tab(for id: String) -> ContainerDetailTab { tabs[id] ?? .logs }

    func setTab(_ tab: ContainerDetailTab, for id: String) {
        guard tabs[id] != tab else { return }
        tabs[id] = tab
        // Keep the dictionary small beyond 200 containers by dropping an arbitrary entry (the alphabetically
        // first key — insertion order is not tracked; losing a remembered tab is harmless).
        if tabs.count > 200, let victim = tabs.keys.sorted().first { tabs[victim] = nil }
        if let data = try? JSONEncoder().encode(tabs) { defaults.set(data, forKey: Self.tabsKey) }
    }

    /// Asks the backend whether "Save as Image…" is available (the backend caches the answer).
    func loadCapabilities(_ backend: any ContainerBackend) async {
        commitSupported = await backend.supportsCommit()
    }

    /// The Files tab model for a container (created on first use; a handful are kept).
    func filesModel(for container: Container, model: AppModel) -> ContainerFilesModel {
        if let existing = filesModels[container.id] { return existing }
        if filesModels.count >= 8, let victim = filesModels.keys.sorted().first { filesModels[victim] = nil }
        let created = ContainerFilesModel(
            containerID: container.id, backend: model.backend, taskCenter: model.taskCenter,
            mounts: container.configuration.mounts)
        filesModels[container.id] = created
        return created
    }

    /// Selects `id` and switches its detail pane to `tab`.
    func open(_ id: String, tab: ContainerDetailTab) {
        selection = [id]
        showDetail = true
        setTab(tab, for: id)
    }
}
