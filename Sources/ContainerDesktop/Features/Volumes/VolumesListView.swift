import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Phase-1 volumes list (features-resources replaces this in phase 2).
struct VolumesListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Volume.ID>()
    @State private var pendingDelete: [String] = []
    @State private var showCreate = false
    @State private var confirmPrune = false

    private var store: VolumesStore { model.volumes }
    private var selected: [Volume] { store.items.filter { selection.contains($0.id) } }

    var body: some View {
        Table(store.filtered, selection: $selection) {
            TableColumn("Name") { v in
                HStack {
                    Text(v.name).fontWeight(.medium)
                    if v.isAnonymous { TagBadge("anonymous") }
                }
            }
            .width(min: 160, ideal: 220)
            TableColumn("In use") { v in
                let users = store.usedBy(v)
                Text(users.isEmpty ? emDash : users.joined(separator: ", ")).foregroundStyle(users.isEmpty ? .secondary : .primary)
            }
            .width(min: 80, ideal: 140)
            TableColumn("Created") { v in Text(RelativeDate.format(v.configuration.creationDate)).foregroundStyle(.secondary) }
                .width(min: 80, ideal: 110)
            TableColumn("Max size") { v in Text(ByteCount.format(v.configuration.sizeInBytes)).monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("Format") { v in Text(v.configuration.format).font(.monoCaption) }
                .width(50)
            TableColumn("Backing file") { v in
                Text(v.configuration.source).font(.monoCaption).foregroundStyle(.secondary).truncationMode(.middle).help(v.configuration.source)
            }
        }
        .contextMenu(forSelectionType: Volume.ID.self) { ids in
            Button("Reveal in Finder") { reveal(ids) }
            Button("Copy name") { copyToPasteboard(ids.joined(separator: "\n")) }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = Array(ids) }
        }
        .overlay {
            if store.filtered.isEmpty && !store.isLoading {
                EmptyStateView(symbol: "externaldrive", title: "No volumes",
                               message: "Volumes keep data across container restarts.", actionTitle: "Create volume…") { showCreate = true }
            }
        }
        .inspector(isPresented: .constant(selected.count == 1)) {
            if let v = selected.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text(v.name).font(.title3.bold())
                        InspectorSection("Volume") {
                            KeyValueGrid([("Driver", v.configuration.driver), ("Format", v.configuration.format),
                                          ("Max size", ByteCount.format(v.configuration.sizeInBytes)),
                                          ("Created", RelativeDate.absolute(v.configuration.creationDate)),
                                          ("Used by", store.usedBy(v).joined(separator: ", ")), ("Source", v.configuration.source)])
                        }
                    }
                    .padding(Spacing.l)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ToolbarActionButton("Create", systemImage: "plus") { showCreate = true }
                ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { pendingDelete = Array(selection) }
                    .disabled(selection.isEmpty)
                ToolbarActionButton("Prune", systemImage: "scissors") { confirmPrune = true }
            }
        }
        .storeChrome(store)
        .deepLinkSelection(.volumes, navigation: model.navigation, selection: $selection) { $0 }
        .sheet(isPresented: $showCreate) { CreateVolumeSheet { name, size in Task { await store.create(name: name, size: size) } } }
        .confirmDestructive(title: "Delete \(pendingDelete.count == 1 ? "volume “\(pendingDelete[0])”" : "\(pendingDelete.count) volumes")?",
                            message: "Deletes \(pendingDelete.joined(separator: ", ")) and all data stored in it.",
                            actionTitle: "Delete",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            let names = pendingDelete
            Task { await store.delete(names); selection.subtract(names) }
        }
        .confirmDestructive(title: "Prune unused volumes?", message: "Deletes every volume not mounted by a container, with its data.",
                            actionTitle: "Prune", isPresented: $confirmPrune) {
            Task { await store.prune() }
        }
    }

    private func reveal(_ ids: Set<String>) {
        let urls = store.items.filter { ids.contains($0.id) }.map {
            URL(fileURLWithPath: ($0.configuration.source as NSString).expandingTildeInPath)
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

private struct CreateVolumeSheet: View {
    let create: (String, MemorySize?) -> Void
    @State private var name = ""
    @State private var size = ""

    var body: some View {
        FormSheet(title: "Create volume", actionTitle: "Create",
                  canSubmit: !name.isEmpty && (size.isEmpty || MemorySize(parsing: size) != nil),
                  submit: { create(name, size.isEmpty ? nil : MemorySize(parsing: size)) }) {
            TextField("Name", text: $name, prompt: Text("pgdata"))
            TextField("Max size", text: $size, prompt: Text("default (512g)"))
            Text("Size is the maximum of a sparse disk image; it only uses what is written.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
