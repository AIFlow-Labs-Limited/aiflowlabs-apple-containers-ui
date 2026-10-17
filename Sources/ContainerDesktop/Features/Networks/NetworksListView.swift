import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Phase-1 networks list (features-resources replaces this in phase 2).
struct NetworksListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Network.ID>()
    @State private var pendingDelete: [String] = []
    @State private var showCreate = false
    @State private var confirmPrune = false

    private var store: NetworksStore { model.networks }
    private var selected: [Network] { store.items.filter { selection.contains($0.id) } }

    var body: some View {
        Table(store.filtered, selection: $selection) {
            TableColumn("Name") { n in
                HStack {
                    Text(n.name).fontWeight(.medium)
                    if n.isBuiltin { TagBadge("default") }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Subnet") { n in Text(n.status?.ipv4Subnet ?? emDash).font(.monoCaption) }
                .width(min: 110, ideal: 140)
            TableColumn("Gateway") { n in Text(n.status?.ipv4Gateway ?? emDash).font(.monoCaption) }
                .width(min: 100, ideal: 120)
            TableColumn("Mode") { n in Text(n.configuration.mode) }
                .width(60)
            TableColumn("Containers") { n in
                let attached = store.attachedContainers(n)
                Text(attached.isEmpty ? emDash : attached.joined(separator: ", ")).foregroundStyle(attached.isEmpty ? .secondary : .primary)
            }
        }
        .contextMenu(forSelectionType: Network.ID.self) { ids in
            Button("Copy name") { copyToPasteboard(ids.joined(separator: "\n")) }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = Array(ids) }
        }
        .overlay {
            if store.filtered.isEmpty && !store.isLoading {
                EmptyStateView(symbol: "network", title: "No networks", message: "The default network appears once the engine runs.")
            }
        }
        .inspector(isPresented: .constant(selected.count == 1)) {
            if let n = selected.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        Text(n.name).font(.title3.bold())
                        InspectorSection("Network") {
                            KeyValueGrid([("Mode", n.configuration.mode), ("Subnet", n.status?.ipv4Subnet ?? ""),
                                          ("IPv6 subnet", n.status?.ipv6Subnet ?? ""), ("Gateway", n.status?.ipv4Gateway ?? ""),
                                          ("Plugin", n.configuration.plugin ?? ""),
                                          ("Containers", store.attachedContainers(n).joined(separator: ", "))])
                        }
                        Text(n.isBuiltin
                             ? "The default network gives containers DNS names under your DNS domain and outbound access."
                             : "Containers on separate networks cannot reach each other. Name resolution between containers needs a DNS domain (Settings → Network).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(Spacing.l)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ToolbarActionButton("Create", systemImage: "plus") { showCreate = true }
                ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { pendingDelete = Array(selection) }
                    .disabled(selection.isEmpty || selected.contains(where: \.isBuiltin))
                ToolbarActionButton("Prune", systemImage: "scissors") { confirmPrune = true }
            }
        }
        .storeChrome(store)
        .deepLinkSelection(.networks, navigation: model.navigation, selection: $selection) { $0 }
        .sheet(isPresented: $showCreate) {
            CreateNetworkSheet { name, subnet in Task { await store.create(name: name, subnet: subnet) } }
        }
        .confirmDestructive(title: "Delete \(pendingDelete.count == 1 ? "network “\(pendingDelete[0])”" : "\(pendingDelete.count) networks")?",
                            message: "Deletes \(pendingDelete.joined(separator: ", ")). Attached containers lose that network.",
                            actionTitle: "Delete",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            let names = pendingDelete
            Task { await store.delete(names); selection.subtract(names) }
        }
        .confirmDestructive(title: "Prune unused networks?", message: "Deletes networks with no containers. The default network is kept.",
                            actionTitle: "Prune", isPresented: $confirmPrune) {
            Task { await store.prune() }
        }
    }
}

private struct CreateNetworkSheet: View {
    let create: (String, String?) -> Void
    @State private var name = ""
    @State private var subnet = ""

    var body: some View {
        FormSheet(title: "Create network", actionTitle: "Create", canSubmit: !name.isEmpty,
                  submit: { create(name, subnet.isEmpty ? nil : subnet) }) {
            TextField("Name", text: $name, prompt: Text("backend"))
            TextField("IPv4 subnet", text: $subnet, prompt: Text("automatic, e.g. 192.168.70.0/24"))
        }
    }
}
