import SwiftUI
import ContainerKit
import ContainerKitMock
import AppCore
import DesignSystem

/// Containers section: table (top) + tabbed detail pane (bottom, resizable) for a single selection.
///
/// Deep links: `navigation.open(.containers, select: "<id>")` selects a container;
/// `select: "run:<image reference>"` opens the Run sheet prefilled with that image.
struct ContainersListView: View {
    @Environment(AppModel.self) private var model
    @State private var ui = ContainersUIState()
    @AppStorage("containers.groupByProject") private var groupByProject = true

    private var store: ContainersStore { model.containers }
    private var actions: ContainerActions { ContainerActions(model: model, ui: ui) }

    private var detailContainer: Container? {
        guard ui.showDetail, ui.selection.count == 1, let id = ui.selection.first else { return nil }
        return store.container(id: id)
    }

    var body: some View {
        VSplitView {
            listArea
                .frame(minHeight: 160, idealHeight: 300, maxHeight: .infinity)
            if let c = detailContainer {
                ContainerDetailView(container: c, ui: ui, actions: actions)
                    .frame(minHeight: 260, idealHeight: 420, maxHeight: .infinity)
            }
        }
        .toolbar { ContainersToolbar(model: model, ui: ui, actions: actions, groupByProject: $groupByProject) }
        .storeChrome(store)
        .deepLinkSelection(.containers, navigation: model.navigation, selection: $ui.selection) { raw in
            if raw.hasPrefix("run:") {
                ui.runRequest = RunSheetRequest(spec: RunSpec(image: String(raw.dropFirst(4))))
                return nil
            }
            ui.showDetail = true
            return raw
        }
        .sheet(item: $ui.runRequest) { request in
            RunContainerSheet(prefill: request.spec) { newID in
                ui.open(newID, tab: .logs)
            }
        }
        .confirmDestructive(title: deleteTitle, message: deleteMessage, actionTitle: "Delete",
                            isPresented: Binding(get: { !ui.pendingDelete.isEmpty }, set: { if !$0 { ui.pendingDelete = [] } })) {
            actions.confirmDelete()
        }
        .confirmDestructive(title: ui.pendingKill.count == 1 ? "Kill “\(ui.pendingKill[0])”?" : "Kill \(ui.pendingKill.count) containers?",
                            message: "Sends SIGKILL to \(ui.pendingKill.joined(separator: ", ")) immediately, without a graceful shutdown. "
                                + "Unsaved data inside the container may be lost.",
                            actionTitle: "Kill",
                            isPresented: Binding(get: { !ui.pendingKill.isEmpty }, set: { if !$0 { ui.pendingKill = [] } })) {
            actions.confirmKill()
        }
        #if DEBUG
        .task { await ContainersDebugHooks.apply(to: ui) }
        #endif
    }

    @ViewBuilder
    private var listArea: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView("Loading containers…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.visibleCount == 0 {
            EmptyStateView(symbol: "shippingbox", title: "No containers yet",
                           message: "Containers you run appear here with live CPU, memory and ports.",
                           actionTitle: "Run a container…") { actions.run() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.filtered.isEmpty {
            EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "No matches",
                           message: "No container matches the current search or filters.",
                           actionTitle: "Clear filters") {
                store.searchText = ""
                store.showStopped = true
                model.settings.showStoppedContainers = true
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContainersTable(ui: ui, rows: ContainerRow.build(store: store, grouped: groupByProject, sortOrder: ui.sortOrder),
                            actions: actions)
        }
    }

    private var deleteTitle: String {
        ui.pendingDelete.count == 1 ? "Delete container “\(ui.pendingDelete[0])”?" : "Delete \(ui.pendingDelete.count) containers?"
    }

    private var deleteMessage: String {
        let names = ui.pendingDelete.prefix(12).joined(separator: ", ")
        let more = ui.pendingDelete.count > 12 ? " and \(ui.pendingDelete.count - 12) more" : ""
        return "Deletes \(names)\(more). Running containers are stopped first. Named volumes are kept."
    }
}

#Preview("Containers") {
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    ContainersListView()
        .appModelEnvironment(model)
        .task { await model.refreshEngine() }
        .frame(width: 1000, height: 700)
}
