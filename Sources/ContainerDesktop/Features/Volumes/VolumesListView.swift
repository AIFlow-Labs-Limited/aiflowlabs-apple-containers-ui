import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// Volumes: table with users, create/delete/prune, reveal backing file, copy `-v` flag, detail inspector.
struct VolumesListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Volume.ID>()
    @State private var sortOrder = [KeyPathComparator(\VolumeRow.name)]
    @State private var pendingDelete: [String] = []
    @State private var showCreate = false
    @State private var confirmPrune = false

    private var store: VolumesStore { model.volumes }

    private var rows: [VolumeRow] {
        let containers = model.containers.items
        return store.filtered.map {
            VolumeRow(volume: $0, usedBy: ResourceUsage.containers(mounting: $0, in: containers))
        }
        .sorted(using: sortOrder)
    }

    private var selectedRows: [VolumeRow] { rows.filter { selection.contains($0.id) } }
    /// From `store.items`, not the filtered rows: `container volume prune` ignores the search field.
    private var pruneCandidates: [String] {
        PruneCandidates.volumes(store.items, containers: model.containers.items).map(\.name)
    }

    var body: some View {
        let rows = rows
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { r in
                HStack(spacing: Spacing.xs) {
                    Text(r.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if r.volume.isAnonymous { TagBadge("anonymous") }
                }
                .help(r.name)
                .accessibilityElement(children: .combine)
            }
            .width(min: 150, ideal: 220)
            TableColumn("In use", value: \.usedCount) { r in
                if r.usedBy.isEmpty {
                    Text(emDash).foregroundStyle(.secondary).accessibilityLabel("Not in use")
                } else {
                    Text(r.usedBy.map(\.id).joined(separator: ", ")).lineLimit(1)
                        .help("Mounted by \(r.usedBy.map(\.id).joined(separator: ", "))")
                        .accessibilityLabel("Mounted by \(r.usedBy.map(\.id).joined(separator: ", "))")
                }
            }
            .width(min: 80, ideal: 140)
            TableColumn("Created", value: \.created) { r in
                Text(RelativeDate.format(r.created)).foregroundStyle(.secondary).help(RelativeDate.absolute(r.created))
            }
            .width(min: 80, ideal: 110)
            TableColumn("Max size", value: \.maxSize) { r in Text(ByteCount.format(r.maxSize)).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("Format", value: \.format) { r in Text(r.format).font(.monoCaption) }
                .width(min: 70, ideal: 90)
            TableColumn("Backing file") { r in
                Text(r.volume.configuration.source).font(.monoCaption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(r.volume.configuration.source)
            }
        }
        .contextMenu(forSelectionType: Volume.ID.self) { ids in contextMenu(ids) }
        .overlay {
            if rows.isEmpty && !store.isLoading {
                EmptyStateView(
                    symbol: "externaldrive", title: store.items.isEmpty ? "No volumes" : "No matching volumes",
                    message: "Volumes keep data across container restarts.", actionTitle: "Create volume…"
                ) { showCreate = true }
            }
        }
        .inspector(isPresented: .constant(selectedRows.count == 1)) {
            if let row = selectedRows.first {
                VolumeDetailView(volume: row.volume, usedBy: row.usedBy) { requestDelete([row.id]) }
                    .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ToolbarActionButton("Create…", systemImage: "plus") { showCreate = true }
                ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { requestDelete(selection) }
                    .disabled(selection.isEmpty || selectedRows.contains { !$0.usedBy.isEmpty })
                ToolbarActionButton("Prune…", systemImage: "scissors") { confirmPrune = true }
                    .disabled(pruneCandidates.isEmpty)
            }
        }
        .storeChrome(store)
        .deepLinkSelection(.volumes, navigation: model.navigation, selection: $selection) { $0 }
        .sheet(isPresented: $showCreate) { CreateVolumeSheet { name in selection = [name] } }
        .confirmDestructive(
            title: pendingDelete.count == 1
                ? "Delete volume “\(pendingDelete[0])”?" : "Delete \(pendingDelete.count) volumes?",
            message:
                "Deletes \(pendingDelete.joined(separator: ", ")) and all data stored in it. This cannot be undone.",
            actionTitle: "Delete",
            isPresented: $pendingDelete.isPresent
        ) {
            let names = pendingDelete
            Task {
                await store.delete(names); selection.subtract(names)
            }
        }
        .confirmDestructive(
            title: PruneText.title(count: pruneCandidates.count, noun: "volume"),
            message: PruneText.message(candidates: pruneCandidates, visible: rows.map(\.name), noun: "volume")
                + " Data in pruned volumes is unrecoverable.",
            actionTitle: "Prune", isPresented: $confirmPrune
        ) {
            Task { await prune() }
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<String>) -> some View {
        let picked = rows.filter { ids.contains($0.id) }
        if let row = picked.first, picked.count == 1 {
            Button("Reveal backing file in Finder") { FilePanels.reveal([row.volume.configuration.source]) }
            Button("Copy mount flag (\(VolumeRow.mountFlag(row.name)))") {
                copyToPasteboard(VolumeRow.mountFlag(row.name))
            }
            Button("Copy name") { copyToPasteboard(row.name) }
        } else if !picked.isEmpty {
            Button("Reveal backing files in Finder") { FilePanels.reveal(picked.map(\.volume.configuration.source)) }
            Button("Copy names") { copyToPasteboard(picked.map(\.name).joined(separator: "\n")) }
        }
        if !picked.isEmpty {
            Divider()
            let users = Set(picked.flatMap { $0.usedBy.map(\.id) }).sorted()
            if users.isEmpty {
                Button("Delete…", role: .destructive) { requestDelete(ids) }
            } else {
                Button("Delete — mounted by \(users.joined(separator: ", "))") {}.disabled(true)
            }
        }
    }

    private func requestDelete(_ ids: Set<String>) {
        let picked = rows.filter { ids.contains($0.id) }
        guard !picked.isEmpty, picked.allSatisfy({ $0.usedBy.isEmpty }) else { return }
        pendingDelete = picked.map(\.name)
    }

    private func prune() async {
        let before = store.items.map(\.name)
        let backend = model.backend
        guard await store.perform({ try await backend.pruneVolumes() }) else { return }
        PruneText.toast(
            model.toasts, removed: PruneCandidates.removed(before: before, after: store.items.map(\.name)),
            noun: "volume")
    }
}

/// Table row with sortable keys.
struct VolumeRow: Identifiable {
    let volume: Volume
    let usedBy: [Container]
    var id: String { volume.id }
    var name: String { volume.name }
    var usedCount: Int { usedBy.count }
    var created: Date { volume.configuration.creationDate }
    var maxSize: Int64 { volume.configuration.sizeInBytes }
    var format: String { "\(volume.configuration.format) · \(volume.configuration.driver)" }

    /// `-v name:/data` for `container run`.
    static func mountFlag(_ name: String, target: String = "/data") -> String { "-v \(name):\(target)" }
}

#Preview("Volumes") {
    NavigationStack { VolumesListView() }
        .appModelEnvironment(ResourcePreview.model())
        .frame(width: 1100, height: 500)
}
