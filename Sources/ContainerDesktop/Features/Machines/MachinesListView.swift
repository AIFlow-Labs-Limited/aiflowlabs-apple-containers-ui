import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Phase-1 machines list (features-platform replaces this in phase 2).
struct MachinesListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Machine.ID>()
    @State private var pendingDelete: [String] = []

    private var store: MachinesStore { model.machines }
    private var selected: [Machine] { store.items.filter { selection.contains($0.id) } }

    var body: some View {
        Table(store.filtered, selection: $selection) {
            TableColumn("Name") { m in
                HStack {
                    StatusDot(m.isRunning ? .statusRunning : .statusStopped, label: m.status.rawValue)
                    Text(m.name).fontWeight(.medium)
                    if m.isDefault { TagBadge("default", tint: .accentColor) }
                }
            }
            .width(min: 140, ideal: 180)
            TableColumn("State") { m in Text(m.status.rawValue.capitalized) }
                .width(70)
            TableColumn("CPUs") { m in Text("\(m.cpus)").monospacedDigit() }
                .width(45)
            TableColumn("Memory") { m in Text(ByteCount.format(m.memory)).monospacedDigit() }
                .width(70)
            TableColumn("Disk") { m in Text(ByteCount.format(m.diskSize)).monospacedDigit() }
                .width(70)
            TableColumn("Image") { m in Text(m.image?.reference ?? emDash).foregroundStyle(.secondary) }
        }
        .contextMenu(forSelectionType: Machine.ID.self) { ids in
            if ids.count == 1, let name = ids.first {
                Button("Set as default") { Task { await store.setDefault(name) } }
            }
            Button("Stop") { Task { await store.stop(Array(ids)) } }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = Array(ids) }
        }
        .overlay {
            if store.filtered.isEmpty && !store.isLoading {
                EmptyStateView(symbol: "desktopcomputer", title: "No machines",
                               message: "A container machine is a persistent Linux box with your home folder mounted.")
            }
        }
        .inspector(isPresented: .constant(selected.count == 1)) {
            if let m = selected.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text(m.name).font(.title3.bold())
                        InspectorSection("Machine") {
                            KeyValueGrid([("State", m.status.rawValue), ("CPUs", "\(m.cpus)"), ("Memory", ByteCount.format(m.memory)),
                                          ("Disk", ByteCount.format(m.diskSize)), ("Image", m.image?.reference ?? ""),
                                          ("Home mount", m.homeMount ?? ""), ("Platform", m.platform?.slug ?? ""),
                                          ("Created", m.createdDate.map(RelativeDate.absolute) ?? "")])
                        }
                        Text("Machines map your home folder into a Linux VM with an init system. Files you change there change on your Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(Spacing.l)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ToolbarActionButton("Set default", systemImage: "star") {
                    if let name = selected.first?.name { Task { await store.setDefault(name) } }
                }
                .disabled(selected.count != 1 || selected.first?.isDefault == true)
                ToolbarActionButton("Stop", systemImage: "stop.fill") { Task { await store.stop(Array(selection)) } }
                    .disabled(!selected.contains(where: \.isRunning))
                ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { pendingDelete = Array(selection) }
                    .disabled(selection.isEmpty)
            }
        }
        .storeChrome(store)
        .deepLinkSelection(.machines, navigation: model.navigation, selection: $selection) { $0 }
        .confirmDestructive(title: "Delete \(pendingDelete.count == 1 ? "machine “\(pendingDelete[0])”" : "\(pendingDelete.count) machines")?",
                            message: "Deletes \(pendingDelete.joined(separator: ", ")) and its disk. Your home folder is not touched.",
                            actionTitle: "Delete",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            let names = pendingDelete
            Task { await store.delete(names); selection.subtract(names) }
        }
    }
}
