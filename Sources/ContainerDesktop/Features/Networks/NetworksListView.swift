import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// Networks: table with attached containers, create/delete/prune, detail with the DNS caveat.
struct NetworksListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Network.ID>()
    @State private var sortOrder = [KeyPathComparator(\NetworkRow.sortKey)]
    @State private var pendingDelete: [String] = []
    @State private var showCreate = false
    @State private var confirmPrune = false

    private var store: NetworksStore { model.networks }

    private var rows: [NetworkRow] {
        let containers = model.containers.items
        return store.filtered.map {
            NetworkRow(network: $0, attached: ResourceUsage.containers(attachedTo: $0, in: containers))
        }
        .sorted(using: sortOrder)
    }

    private var selectedRows: [NetworkRow] { rows.filter { selection.contains($0.id) } }
    /// From `store.items`, not the filtered rows: `container network prune` ignores the search field.
    private var pruneCandidates: [String] {
        PruneCandidates.networks(store.items, containers: model.containers.items).map(\.name)
    }

    var body: some View {
        let rows = rows
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.sortKey) { r in
                HStack(spacing: Spacing.xs) {
                    Text(r.name).fontWeight(.medium)
                    if r.network.isBuiltin { TagBadge("built-in", tint: .accentColor).fixedSize() }
                }
                .accessibilityElement(children: .combine)
            }
            .width(min: 170, ideal: 220)
            TableColumn("Subnet", value: \.subnet) { r in Text(r.subnet.isEmpty ? emDash : r.subnet).font(.monoCaption)
            }
            .width(min: 110, ideal: 140)
            TableColumn("Gateway", value: \.gateway) { r in
                Text(r.gateway.isEmpty ? emDash : r.gateway).font(.monoCaption)
            }
            .width(min: 100, ideal: 120)
            TableColumn("IPv6 subnet", value: \.subnetV6) { r in
                Text(r.subnetV6.isEmpty ? emDash : r.subnetV6).font(.monoCaption).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 100, ideal: 160)
            TableColumn("Containers", value: \.attachedCount) { r in
                if r.attached.isEmpty {
                    Text(emDash).foregroundStyle(.secondary).accessibilityLabel("No containers")
                } else {
                    HStack(spacing: Spacing.xs) {
                        Text("\(r.attached.count)").monospacedDigit().fontWeight(.medium)
                        Text(r.attached.map(\.id).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(r.attached.map(\.id).joined(separator: ", "))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "\(r.attached.count) containers: \(r.attached.map(\.id).joined(separator: ", "))")
                }
            }
        }
        .contextMenu(forSelectionType: Network.ID.self) { ids in contextMenu(ids) }
        .overlay {
            if rows.isEmpty && !store.isLoading {
                EmptyStateView(
                    symbol: "network", title: store.items.isEmpty ? "No networks" : "No matching networks",
                    message: "The default network appears once the engine runs.",
                    actionTitle: "Create network…"
                ) { showCreate = true }
            }
        }
        .inspector(isPresented: .constant(selectedRows.count == 1)) {
            if let row = selectedRows.first {
                NetworkDetailView(network: row.network, attached: row.attached)
                    .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ToolbarActionButton("Create…", systemImage: "plus") { showCreate = true }
                ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { requestDelete(selection) }
                    .disabled(selectedRows.isEmpty || selectedRows.contains { $0.blockReason != nil })
                ToolbarActionButton("Prune…", systemImage: "scissors") { confirmPrune = true }
                    .disabled(pruneCandidates.isEmpty)
            }
        }
        .storeChrome(store)
        .deepLinkSelection(.networks, navigation: model.navigation, selection: $selection) { $0 }
        .sheet(isPresented: $showCreate) { CreateNetworkSheet { name in selection = [name] } }
        .confirmDestructive(
            title: pendingDelete.count == 1
                ? "Delete network “\(pendingDelete[0])”?" : "Delete \(pendingDelete.count) networks?",
            message: "Deletes \(pendingDelete.joined(separator: ", ")). No containers are attached.",
            actionTitle: "Delete",
            isPresented: $pendingDelete.isPresent
        ) {
            let names = pendingDelete
            Task {
                await store.delete(names); selection.subtract(names)
            }
        }
        .confirmDestructive(
            title: PruneText.title(count: pruneCandidates.count, noun: "network"),
            message: PruneText.message(candidates: pruneCandidates, visible: rows.map(\.name), noun: "network")
                + " The default network is kept.",
            actionTitle: "Prune", isPresented: $confirmPrune
        ) {
            Task { await prune() }
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: Set<String>) -> some View {
        let picked = rows.filter { ids.contains($0.id) }
        if !picked.isEmpty {
            Button(picked.count == 1 ? "Copy name" : "Copy names") {
                copyToPasteboard(picked.map(\.name).joined(separator: "\n"))
            }
            if let row = picked.first, picked.count == 1, !row.subnet.isEmpty {
                Button("Copy subnet") { copyToPasteboard(row.subnet) }
                Button("Copy --network flag") { copyToPasteboard("--network \(row.name)") }
            }
            Divider()
            if let reason = picked.lazy.compactMap(\.blockReason).first {
                Button("Delete — \(reason)") {}.disabled(true)
            } else {
                Button("Delete…", role: .destructive) { requestDelete(ids) }
            }
        }
    }

    private func requestDelete(_ ids: Set<String>) {
        let picked = rows.filter { ids.contains($0.id) }
        guard !picked.isEmpty, picked.allSatisfy({ $0.blockReason == nil }) else { return }
        pendingDelete = picked.map(\.name)
    }

    private func prune() async {
        let before = store.items.map(\.name)
        let backend = model.backend
        guard await store.perform({ try await backend.pruneNetworks() }) else { return }
        PruneText.toast(
            model.toasts, removed: PruneCandidates.removed(before: before, after: store.items.map(\.name)),
            noun: "network")
    }
}

/// Table row with sortable keys.
struct NetworkRow: Identifiable {
    let network: Network
    let attached: [Container]
    var id: String { network.id }
    var name: String { network.name }
    /// Built-in first, then by name.
    var sortKey: String { (network.isBuiltin ? "0" : "1") + network.name }
    var subnet: String { network.status?.ipv4Subnet ?? "" }
    var gateway: String { network.status?.ipv4Gateway ?? "" }
    var subnetV6: String { network.status?.ipv6Subnet ?? "" }
    var attachedCount: Int { attached.count }

    /// Why this network cannot be deleted, if it cannot.
    var blockReason: String? {
        if network.isBuiltin { return "the built-in network can't be removed" }
        if !attached.isEmpty { return "attached to \(attached.map(\.id).joined(separator: ", "))" }
        return nil
    }
}

#Preview("Networks") {
    NavigationStack { NetworksListView() }
        .appModelEnvironment(ResourcePreview.model())
        .frame(width: 1100, height: 500)
}
