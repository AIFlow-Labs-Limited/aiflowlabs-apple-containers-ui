import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Toolbar for the containers section: Run (⌘N), bulk lifecycle actions, view options.
struct ContainersToolbar: ToolbarContent {
    let model: AppModel
    let ui: ContainersUIState
    let actions: ContainerActions
    @Binding var groupByProject: Bool

    private var store: ContainersStore { model.containers }
    private var selectedIDs: [String] { store.containerIDs(for: ui.selection) }
    private var selected: [Container] { selectedIDs.compactMap(store.container(id:)) }

    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { actions.run() } label: { Label("Run", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: .command)
                .help("Run a new container (⌘N)")
                .accessibilityLabel("Run a new container")
        }
        ToolbarItemGroup {
            ToolbarActionButton("Start", systemImage: "play.fill") { actions.start(selectedIDs) }
                .disabled(!selected.contains { !$0.isRunning })
            ToolbarActionButton("Stop", systemImage: "stop.fill") { actions.stop(selectedIDs) }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!selected.contains(where: \.isRunning))
            ToolbarActionButton("Restart", systemImage: "arrow.clockwise.circle") { actions.restart(selectedIDs) }
                .disabled(selected.isEmpty)
            ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { actions.requestDelete(selectedIDs) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selected.isEmpty)
            Menu {
                Toggle("Show Stopped Containers", isOn: Binding(
                    get: { store.showStopped },
                    set: { store.showStopped = $0; model.settings.showStoppedContainers = $0 }))
                Toggle("Hide System Containers", isOn: Binding(
                    get: { store.hideSystemManaged },
                    set: { store.hideSystemManaged = $0; model.settings.hideSystemContainers = $0 }))
                    .help("Builder and Kubernetes node containers")
                Toggle("Group by Project", isOn: $groupByProject)
                Divider()
                Button("Prune Stopped Containers…") { requestPrune() }
                    .disabled(!store.items.contains { !$0.isRunning && !$0.isSystemManaged })
            } label: {
                Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Filters and grouping (right-click a column header to show or hide columns)")
        }
    }

    private func requestPrune() {
        ui.pendingDelete = store.items.filter { !$0.isRunning && !$0.isSystemManaged }.map(\.id)
    }
}
