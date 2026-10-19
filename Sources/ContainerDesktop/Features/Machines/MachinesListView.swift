import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Machines: table (sortable, searchable), create / resize / terminal / logs / stop / delete / set default,
/// and an inspector with Overview · Terminal · Logs.
struct MachinesListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Machine.ID>()
    @State private var sortOrder = [KeyPathComparator(\Machine.name)]
    @State private var detailTab = MachineDetailTab.overview
    /// `machine ls` lacks image/user info; filled from `machine inspect` per name.
    @State private var details: [String: Machine] = [:]
    @State private var showCreate = false
    @State private var resizing: Machine?
    @State private var pendingDelete: [String] = []
    @State private var pendingStop: [String] = []

    private var store: MachinesStore { model.machines }
    private var rows: [Machine] { store.filtered.map { enriched($0) }.sorted(using: sortOrder) }
    private var selected: [Machine] { rows.filter { selection.contains($0.id) } }

    var body: some View {
        table
            .overlay { emptyState }
            .inspector(isPresented: .constant(selected.count == 1)) {
                if let m = selected.first {
                    MachineDetailView(machine: m, tab: $detailTab,
                                      onResize: { resizing = m }, onStop: { pendingStop = [m.name] })
                        .inspectorColumnWidth(min: 340, ideal: 400, max: 900)
                }
            }
            .toolbar { toolbar }
            .storeChrome(store)
            .deepLinkSelection(.machines, navigation: model.navigation, selection: $selection) { $0 }
            .task(id: store.items.map(\.name)) { await loadDetails() }
            .sheet(isPresented: $showCreate) {
                CreateMachineSheet(localImages: model.images.items.map(\.reference),
                                   existingNames: store.items.map(\.name)) { spec in
                    store.create(spec)
                }
                .task { await model.images.refresh() }
            }
            .sheet(item: $resizing) { m in
                ResizeMachineSheet(machine: m) { cpus, memoryGB in
                    await store.configure(m.name, settings: MachineResize.settings(cpus: cpus, memoryGB: memoryGB))
                } stop: {
                    await store.stop([m.name])
                }
            }
            .confirmDestructive(title: deleteTitle, message: deleteMessage, actionTitle: "Delete",
                                isPresented: $pendingDelete.isPresent) {
                let names = pendingDelete
                Task { await store.delete(names); selection.subtract(names) }
            }
            .confirmDestructive(title: "Stop \(listed(pendingStop))?",
                                message: "Shuts down \(listed(pendingStop)). Open terminal sessions end; files on its disk and in your home folder stay.",
                                actionTitle: "Stop", isPresented: $pendingStop.isPresent) {
                let names = pendingStop
                Task { await store.stop(names) }
            }
            #if DEBUG
            .debugHook("machine-create") { showCreate = true }
            .debugHook("machine-select") { selection = Set(store.items.prefix(1).map(\.name)) }
            #endif
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { m in
                Text(m.name).fontWeight(.medium)
                    .accessibilityLabel("Machine \(m.name), \(m.status.rawValue)\(m.isDefault ? ", default" : "")")
            }
            .width(min: 120, ideal: 160)
            TableColumn("State", value: \.status.rawValue) { m in
                HStack(spacing: Spacing.xs) {
                    StatusDot(m.isRunning ? .statusRunning : .statusStopped, label: m.status.rawValue)
                    Text(m.status.rawValue.capitalized)
                }
            }
            .width(min: 70, ideal: 85)
            TableColumn("CPUs", value: \.cpus) { m in Text("\(m.cpus)").monospacedDigit() }
                .width(45)
            TableColumn("Memory", value: \.memory) { m in Text(ByteCount.format(m.memory)).monospacedDigit() }
                .width(min: 60, ideal: 75)
            TableColumn("Disk", value: \.diskSize) { m in Text(ByteCount.format(m.diskSize)).monospacedDigit() }
                .width(min: 60, ideal: 75)
            TableColumn("Default", value: \.defaultRank) { m in
                if m.isDefault {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Default machine")
                }
            }
            .width(50)
            TableColumn("Image", value: \.imageReference) { m in
                Text(m.image?.reference ?? emDash).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 140, ideal: 240)
            TableColumn("Created", value: \.createdSort) { m in
                Text(m.createdDate.map { RelativeDate.format($0) } ?? emDash).foregroundStyle(.secondary)
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: Machine.ID.self) { ids in rowMenu(ids) } primaryAction: { ids in
            if let name = ids.first { openTerminal(name) }
        }
    }

    @ViewBuilder
    private func rowMenu(_ ids: Set<Machine.ID>) -> some View {
        if ids.count == 1, let name = ids.first, let m = rows.first(where: { $0.id == name }) {
            Button("Open Terminal") { openTerminal(name) }
            Button("View Logs") { selection = [name]; detailTab = .logs }
            Divider()
            Button("Resize…") { resizing = m }
            Button("Set as Default") { Task { await store.setDefault(name) } }
                .disabled(m.isDefault)
            Button("Copy Name") { copyToPasteboard(name) }
            Divider()
        }
        Button("Stop") { pendingStop = Array(ids) }
            .disabled(!rows.contains { ids.contains($0.id) && $0.isRunning })
        Button("Delete…", role: .destructive) { pendingDelete = Array(ids) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            ToolbarActionButton("New Machine", systemImage: "plus") { showCreate = true }
            ToolbarActionButton("Terminal", systemImage: "apple.terminal") {
                if let name = selected.first?.name { openTerminal(name) }
            }
            .disabled(selected.count != 1)
            ToolbarActionButton("Set Default", systemImage: "star") {
                if let name = selected.first?.name { Task { await store.setDefault(name) } }
            }
            .disabled(selected.count != 1 || selected.first?.isDefault == true)
            ToolbarActionButton("Stop", systemImage: "stop.fill") { pendingStop = selected.filter(\.isRunning).map(\.name) }
                .disabled(!selected.contains(where: \.isRunning))
            ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { pendingDelete = Array(selection) }
                .disabled(selection.isEmpty)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.filtered.isEmpty && !store.isLoading {
            if store.searchText.isEmpty {
                EmptyStateView(symbol: "desktopcomputer", title: "No machines",
                               message: "A container machine is a persistent Linux box with your home folder at the same path, your user name and a real init system.",
                               actionTitle: "New Machine…") { showCreate = true }
            } else {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
    }

    // MARK: Helpers

    private func openTerminal(_ name: String) {
        selection = [name]
        detailTab = .terminal
    }

    private func enriched(_ m: Machine) -> Machine {
        guard let d = details[m.name] else { return m }
        var out = m
        out.image = out.image ?? d.image
        out.userSetup = out.userSetup ?? d.userSetup
        out.homeMount = out.homeMount ?? d.homeMount
        out.platform = out.platform ?? d.platform
        return out
    }

    private func loadDetails() async {
        for m in store.items where m.image == nil && details[m.name] == nil {
            if let full = await store.inspect(m.name) { details[m.name] = full }
        }
        details = details.filter { name, _ in store.items.contains { $0.name == name } }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete machine “\(pendingDelete[0])”?" : "Delete \(pendingDelete.count) machines?"
    }

    private var deleteMessage: String {
        "Deletes \(listed(pendingDelete)) and \(pendingDelete.count == 1 ? "its disk" : "their disks") (anything installed inside). "
            + "Your home folder is NOT touched."
    }

}

/// Sort keys for columns whose model fields aren't `Comparable`.
extension Machine {
    var defaultRank: Int { isDefault ? 0 : 1 }
    var imageReference: String { image?.reference ?? "" }
    var createdSort: Date { createdDate ?? .distantPast }
}

#Preview("Machines") {
    MachinesListView()
        .appModelEnvironment(ResourcePreview.model())
        .frame(width: 1100, height: 600)
}
