import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Phase-1 Kubernetes clusters list (features-platform replaces this in phase 2).
struct KubernetesListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<KubernetesCluster.ID>()
    @State private var pendingDelete: [String] = []
    @State private var showCreate = false

    private var store: ClustersStore { model.clusters }
    private var selected: [KubernetesCluster] { store.items.filter { selection.contains($0.id) } }

    var body: some View {
        Table(store.filtered, selection: $selection) {
            TableColumn("Name") { c in
                HStack {
                    StatusDot(c.isRunning ? .statusRunning : .statusStopped, label: c.isRunning ? "Running" : "Stopped")
                    Text(c.name).fontWeight(.medium)
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Nodes") { c in Text("\(c.nodes.count)").monospacedDigit() }
                .width(50)
            TableColumn("State") { c in Text(c.isRunning ? "Running" : "Stopped") }
                .width(70)
            TableColumn("Context") { c in Text("kubectl --context \(c.kubeContext)").font(.monoCaption).foregroundStyle(.secondary) }
        }
        .contextMenu(forSelectionType: KubernetesCluster.ID.self) { ids in
            Button("Copy kubectl context") { copyToPasteboard(ids.map { "kubectl --context \($0)" }.joined(separator: "\n")) }
            Divider()
            Button("Delete…", role: .destructive) { pendingDelete = Array(ids) }
        }
        .overlay {
            if store.filtered.isEmpty && !store.isLoading {
                EmptyStateView(symbol: "helm", title: "No clusters", message: "Create a local Kubernetes cluster (experimental).",
                               actionTitle: "Create cluster…") { showCreate = true }
            }
        }
        .inspector(isPresented: .constant(selected.count == 1)) {
            if let c = selected.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.m) {
                        HStack { Text(c.name).font(.title3.bold()); TagBadge("Experimental", tint: .statusWarning) }
                        ForEach(c.nodes) { node in
                            InspectorSection(node.name) {
                                KeyValueGrid([("Role", node.role), ("State", node.state.displayName), ("CPUs", "\(node.cpus)"),
                                              ("Memory", "\(node.memoryMB) MB"), ("Address", node.address ?? ""), ("Ports", node.ports ?? "")])
                            }
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
            }
        }
        .storeChrome(store)
        .sheet(isPresented: $showCreate) {
            CreateClusterSheet { name in store.create(ClusterSpec(name: name)) }
        }
        .confirmDestructive(title: "Delete \(pendingDelete.count == 1 ? "cluster “\(pendingDelete[0])”" : "\(pendingDelete.count) clusters")?",
                            message: "Deletes \(pendingDelete.joined(separator: ", ")) and all its nodes and workloads.",
                            actionTitle: "Delete",
                            isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
            let names = pendingDelete
            Task { await store.delete(names); selection.subtract(names) }
        }
    }
}

private struct CreateClusterSheet: View {
    let create: (String) -> Void
    @State private var name = "k8s-dev"

    var body: some View {
        FormSheet(title: "Create Kubernetes cluster", actionTitle: "Create", canSubmit: !name.isEmpty, submit: { create(name) }) {
            TextField("Name", text: $name)
            Text("Creation streams into the Activity window and takes a few minutes the first time.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
