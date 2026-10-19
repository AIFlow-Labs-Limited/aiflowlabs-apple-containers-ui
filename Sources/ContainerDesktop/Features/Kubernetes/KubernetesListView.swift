import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Kubernetes (experimental `container k8s` plugin): clusters with expandable node rows, create / delete /
/// load image / copy kubectl context, and a detail inspector.
struct KubernetesListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<ClusterRow.ID>()
    @State private var showCreate = false
    @State private var loadInto: String?
    @State private var pendingDelete: [String] = []

    static let docsURL = URL(string: "https://github.com/apple/container/tree/main/docs")!

    private var store: ClustersStore { model.clusters }
    private var rows: [ClusterRow] { store.filtered.map(ClusterRow.init(cluster:)) }
    private var selectedNames: [String] { Array(Set(selection.map(ClusterRow.clusterName(of:)))).sorted() }
    private var selectedCluster: KubernetesCluster? {
        selectedNames.count == 1 ? store.items.first { $0.name == selectedNames[0] } : nil
    }

    var body: some View {
        content
            .toolbar { toolbar }
            .storeChrome(store)
            .deepLinkSelection(.kubernetes, navigation: model.navigation, selection: $selection) { $0 }
            .sheet(isPresented: $showCreate) {
                CreateClusterSheet { spec in store.create(spec) }
            }
            .sheet(item: Binding(get: { loadInto.map(IdentifiedName.init) }, set: { loadInto = $0?.id })) { target in
                LoadImageSheet(cluster: target.id, localImages: model.images.items.map(\.reference)) { ref, platform in
                    store.loadImage(ref, into: target.id, platform: platform)
                }
                .task { await model.images.refresh() }
            }
            .confirmDestructive(title: deleteTitle,
                                message: "Deletes \(listed(pendingDelete)) with all \(pendingDelete.count == 1 ? "its" : "their") nodes, workloads and loaded images, and removes the kubectl context.",
                                actionTitle: "Delete",
                                isPresented: $pendingDelete.isPresent) {
                let names = pendingDelete
                Task { await store.delete(names); selection = selection.filter { !names.contains(ClusterRow.clusterName(of: $0)) } }
            }
            #if DEBUG
            .debugHook("cluster-create") { showCreate = true }
            .debugHook("cluster-select") { selection = Set(store.items.prefix(1).map(\.name)) }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if !store.available && !store.isLoading {
            ContentUnavailableView {
                Label("Kubernetes isn't available", systemImage: "helm")
            } description: {
                Text("The k8s plugin isn't available in this `container` build, or the engine isn't running. It ships as an experimental plugin with recent releases.")
            } actions: {
                Link("Read the container docs", destination: Self.docsURL)
            }
        } else {
            VStack(spacing: 0) {
                SectionHeaderBar(subtitle: "Local clusters — each node is a container (kind).", badge: "Experimental") {
                    Link("Docs", destination: Self.docsURL).font(.callout)
                }
                Divider()
                table
                    .overlay { emptyState }
            }
                .inspector(isPresented: .constant(selectedCluster != nil)) {
                    if let c = selectedCluster {
                        ClusterDetailView(cluster: c, onLoadImage: { loadInto = c.name }, onDelete: { pendingDelete = [c.name] })
                            .inspectorColumnWidth(min: 340, ideal: 420, max: 700)
                    }
                }
        }
    }

    private var table: some View {
        Table(rows, children: \.children, selection: $selection) {
            TableColumn("Name") { row in
                HStack(spacing: Spacing.xs) {
                    StatusDot(row.isRunning ? .statusRunning : .statusStopped, label: row.stateLabel)
                    Text(row.title).fontWeight(row.node == nil ? .medium : .regular)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.node == nil ? "Cluster \(row.title), \(row.stateLabel)" : "Node \(row.title), \(row.stateLabel)")
            }
            .width(min: 140, ideal: 200)
            TableColumn("Nodes") { row in
                Text(row.node?.role ?? "\(row.cluster.nodes.count)").monospacedDigit()
            }
            .width(min: 50, ideal: 90)
            TableColumn("State") { row in Text(row.stateLabel) }
                .width(min: 60, ideal: 75)
            TableColumn("CPUs") { row in Text("\(row.cpus)").monospacedDigit() }
                .width(45)
            TableColumn("Memory") { row in Text(ByteCount.format(row.memoryMB << 20)).monospacedDigit() }
                .width(min: 60, ideal: 75)
            TableColumn("Address") { row in
                Text(row.address ?? emDash).font(.monoCaption).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("kubectl context") { row in
                if row.node == nil {
                    HStack(spacing: Spacing.xs) {
                        Text(KubectlCommands.context(row.cluster.name)).font(.monoCaption).foregroundStyle(.secondary)
                            .lineLimit(1)
                        CopyButton(KubectlCommands.context(row.cluster.name), label: "Copy kubectl context")
                    }
                } else {
                    Text(row.node?.ports ?? "").font(.monoCaption).foregroundStyle(.tertiary)
                }
            }
            .width(min: 160, ideal: 220)
        }
        .contextMenu(forSelectionType: ClusterRow.ID.self) { ids in
            let names = Array(Set(ids.map(ClusterRow.clusterName(of:)))).sorted()
            if names.count == 1 {
                Button("Load Image…") { loadInto = names[0] }
                Button("Copy kubectl Context") { copyToPasteboard(KubectlCommands.context(names[0])) }
                Button("Copy “get nodes” Command") { copyToPasteboard("\(KubectlCommands.context(names[0])) get nodes") }
                Divider()
            }
            Button("Delete…", role: .destructive) { pendingDelete = names }
                .disabled(names.isEmpty)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            ToolbarActionButton("New Cluster", systemImage: "plus") { showCreate = true }
                .disabled(!store.available)
            ToolbarActionButton("Load Image", systemImage: "square.and.arrow.down.on.square") {
                loadInto = selectedNames.first
            }
            .disabled(selectedNames.count != 1)
            ToolbarActionButton("Copy Context", systemImage: "doc.on.doc") {
                if let n = selectedNames.first { copyToPasteboard(KubectlCommands.context(n)) }
            }
            .disabled(selectedNames.count != 1)
            ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { pendingDelete = selectedNames }
                .disabled(selectedNames.isEmpty)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.filtered.isEmpty && !store.isLoading {
            if store.searchText.isEmpty {
                EmptyStateView(symbol: "helm", title: "No clusters",
                               message: "Create a local Kubernetes cluster. The first one downloads the node image (about 1 GB) and takes a few minutes.",
                               actionTitle: "New Cluster…") { showCreate = true }
            } else {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
    }

    private var deleteTitle: String {
        pendingDelete.count == 1 ? "Delete cluster “\(pendingDelete[0])”?" : "Delete \(pendingDelete.count) clusters?"
    }

}

/// A table row: a cluster (with node children) or one of its nodes.
struct ClusterRow: Identifiable, Hashable {
    let id: String
    let cluster: KubernetesCluster
    let node: KubernetesCluster.Node?
    let children: [ClusterRow]?

    private static let separator: Character = "\u{1F}"

    init(cluster: KubernetesCluster) {
        id = cluster.name
        self.cluster = cluster
        node = nil
        children = cluster.nodes.isEmpty ? nil : cluster.nodes.map { ClusterRow(cluster: cluster, node: $0) }
    }

    private init(cluster: KubernetesCluster, node: KubernetesCluster.Node) {
        id = cluster.name + String(Self.separator) + node.name
        self.cluster = cluster
        self.node = node
        children = nil
    }

    /// The cluster a row id belongs to (node ids carry the cluster name as a prefix).
    static func clusterName(of id: ID) -> String {
        String(id.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(id))
    }

    var title: String { node?.name ?? cluster.name }
    var isRunning: Bool { node.map { $0.state == .running } ?? cluster.isRunning }
    var stateLabel: String {
        if let node { return node.state.displayName }
        if cluster.nodes.isEmpty { return "Unknown" }
        return cluster.isRunning ? "Running" : "Stopped"
    }
    var cpus: Int { node?.cpus ?? cluster.nodes.reduce(0) { $0 + $1.cpus } }
    var memoryMB: Int64 { node?.memoryMB ?? cluster.nodes.reduce(0) { $0 + $1.memoryMB } }
    var address: String? { node?.address ?? cluster.nodes.first { $0.role.contains("control") }?.address ?? cluster.nodes.first?.address }
}

/// Wraps a name so it can drive `.sheet(item:)`.
struct IdentifiedName: Identifiable { let id: String }

#Preview("Kubernetes") {
    KubernetesListView()
        .appModelEnvironment(ResourcePreview.model())
        .frame(width: 1100, height: 600)
}
