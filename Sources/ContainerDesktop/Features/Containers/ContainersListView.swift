import SwiftUI
import AppKit
import ContainerKit
import ContainerKitMock
import AppCore
import DesignSystem

/// Containers section: table (top) + tabbed detail pane (bottom, resizable) for a single selection.
///
/// Deep links: `navigation.open(.containers, select: "<id>")` selects a container;
/// `select: "run:<image reference>"` or `model.runRequests.request(_:)` opens the Run sheet prefilled.
struct ContainersListView: View {
    @Environment(AppModel.self) private var model
    @State private var ui = ContainersUIState()
    @AppStorage("containers.groupByProject") private var groupByProject = true
    @AppStorage("containers.listHeight") private var listHeight: Double = 300

    private var store: ContainersStore { model.containers }
    private var actions: ContainerActions { ContainerActions(model: model, ui: ui) }

    private var detailContainer: Container? {
        guard ui.showDetail, ui.selection.count == 1, let id = ui.selection.first else { return nil }
        return store.container(id: id)
    }

    var body: some View {
        // A VStack + drag handle instead of `VSplitView`: VSplitView mis-applies the toolbar safe area to its
        // first pane and leaves a dead band above the second one.
        GeometryReader { geo in
            VStack(spacing: 0) {
                if let c = detailContainer {
                    let height = min(max(160, listHeight), max(160, geo.size.height - 260))
                    listArea.frame(height: height)
                    SplitHandle(height: $listHeight, range: 160...max(160, geo.size.height - 260))
                    ContainerDetailView(container: c, ui: ui, actions: actions)
                        .frame(maxHeight: .infinity)
                } else {
                    listArea.frame(maxHeight: .infinity)
                }
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
        // "Run…" from Images (and other sections) hands off through `model.runRequests`.
        .onAppear(perform: consumeRunRequest)
        .onChange(of: model.runRequests.pending) { consumeRunRequest() }
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
        } else if store.filtered.isEmpty, store.searchText.trimmingCharacters(in: .whitespaces).isEmpty, !store.showStopped {
            let hidden = store.items.count { !$0.isRunning && (!store.hideSystemManaged || !$0.isSystemManaged) }
            EmptyStateView(symbol: "stop.circle", title: "No running containers",
                           message: "\(hidden) stopped container\(hidden == 1 ? " is" : "s are") hidden.",
                           actionTitle: "Show stopped containers") {
                store.showStopped = true
                model.settings.showStoppedContainers = true
            }
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

    private func consumeRunRequest() {
        guard model.runRequests.pending != nil, let spec = model.runRequests.consume() else { return }
        // `RunSpec(image: "")` is the "blank sheet" request (File › Run Container… / ⌘N).
        ui.runRequest = RunSheetRequest(spec: spec == RunSpec(image: "") ? nil : spec)
    }

    private var deleteTitle: String {
        ui.pendingDelete.count == 1 ? "Delete container “\(ui.pendingDelete[0])”?" : "Delete \(ui.pendingDelete.count) containers?"
    }

    private var deleteMessage: String {
        let names = ui.pendingDelete.prefix(12).joined(separator: ", ")
        let more = ui.pendingDelete.count > 12 ? " and \(ui.pendingDelete.count - 12) more" : ""
        let running = ui.pendingDelete.filter { store.container(id: $0)?.isRunning == true }
        let runningNote = running.isEmpty ? "" : " Running containers (\(running.count)) are killed and removed."
        return "Deletes \(names)\(more).\(runningNote) Named volumes are kept."
    }
}

/// Horizontal divider that resizes the pane above it by dragging.
private struct SplitHandle: View {
    @Binding var height: Double
    let range: ClosedRange<Double>
    @State private var start: Double?

    var body: some View {
        Divider()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)   // balanced by SwiftUI, unlike NSCursor.push/pop on hover
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = start ?? height
                    start = base
                    height = min(max(base + value.translation.height, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in start = nil })
            .accessibilityLabel("Resize list and details")
            .accessibilityAdjustableAction { direction in
                height = min(max(height + (direction == .increment ? 40 : -40), range.lowerBound), range.upperBound)
            }
    }
}

#Preview("Containers") {
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    ContainersListView()
        .appModelEnvironment(model)
        .task { await model.refreshEngine() }
        .frame(width: 1000, height: 700)
}
