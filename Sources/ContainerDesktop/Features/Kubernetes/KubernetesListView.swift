import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// Kubernetes (Apple's experimental plugin: `container k8s` up to 1.6.0, `container cluster` after): clusters with
/// expandable node rows, create / delete / load image / copy kubectl context, and a detail inspector. What is
/// offered follows `ClustersStore.capabilities`, detected from the installed CLI.
struct KubernetesListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<ClusterRow.ID>()
    @State private var showCreate = false
    @State private var loadInto: String?
    @State private var pendingDelete: [String] = []
    #if DEBUG
        @State private var debugSelect = false

        /// `cluster-select`: the first running cluster (else the first), as soon as clusters are listed.
        private func selectForDebug() {
            guard debugSelect, let cluster = store.items.first(where: \.isRunning) ?? store.items.first else { return }
            debugSelect = false
            selection = [cluster.name]
        }
    #endif

    static let docsURL = URL(string: "https://github.com/apple/container/tree/main/docs")!

    private var store: ClustersStore { model.clusters }
    private var capabilities: KubernetesCapabilities { store.effectiveCapabilities }
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
                CreateClusterSheet(capabilities: capabilities, existingNames: store.items.map(\.name)) { spec in
                    store.create(spec)
                }
            }
            .sheet(item: Binding(get: { loadInto.map(IdentifiedName.init) }, set: { loadInto = $0?.id })) { target in
                LoadImageSheet(
                    cluster: target.id, localImages: model.images.items.map(\.reference), capabilities: capabilities
                ) { ref, platform in
                    store.loadImage(ref, into: target.id, platform: platform)
                }
                .task { await model.images.refresh() }
            }
            .confirmDestructive(
                title: deleteTitle,
                message:
                    "Deletes \(listed(pendingDelete)) with all \(pendingDelete.count == 1 ? "its" : "their") nodes and workloads, and removes the kubectl context.",
                actionTitle: "Delete",
                isPresented: $pendingDelete.isPresent
            ) {
                let names = pendingDelete
                Task {
                    await store.delete(names);
                    selection = selection.filter { !names.contains(ClusterRow.clusterName(of: $0)) }
                }
            }
            #if DEBUG
                .debugHook("cluster-create") { showCreate = true }
                .debugHook("cluster-select") { debugSelect = true }
                // A real engine lists its clusters after the hook fires; select once there is one.
                .onChange(of: store.items.isEmpty, initial: true) { selectForDebug() }
                .onChange(of: debugSelect) { selectForDebug() }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if !store.available && !store.isLoading {
            ContentUnavailableView {
                Label("Kubernetes isn't available", systemImage: "helm")
            } description: {
                Text(
                    "The Kubernetes plugin (`container cluster`, or `container k8s` on older releases) isn't available in this `container` build, or the engine isn't running. Apple ships it as an experimental plugin with recent releases."
                )
            } actions: {
                Link("Read the container docs", destination: Self.docsURL)
            }
        } else {
            VStack(spacing: 0) {
                SectionHeaderBar(subtitle: "Local clusters — each node is a container (kind).", badge: "Experimental") {
                    Link("Docs", destination: Self.docsURL).font(.callout)
                }
                Divider()
                if let c = selectedCluster {
                    // The selected cluster's pods, deployments and services, under the cluster list.
                    VSplitView {
                        table.frame(minHeight: 80, idealHeight: 130, maxHeight: 240)
                        ClusterWorkloadsView(cluster: c).frame(minHeight: 220, idealHeight: 420)
                    }
                } else {
                    table
                        .overlay { emptyState }
                }
            }
            .inspector(isPresented: .constant(selectedCluster != nil)) {
                if let c = selectedCluster {
                    ClusterDetailView(
                        cluster: c, capabilities: capabilities, onLoadImage: { loadInto = c.name },
                        onDelete: { pendingDelete = [c.name] }
                    )
                    .inspectorColumnWidth(min: 340, ideal: 420, max: 700)
                }
            }
        }
    }

    private var table: some View {
        Table(rows, children: \.children, selection: $selection) {
            TableColumn("Name") { row in
                HStack(spacing: Spacing.xs) {
                    StatusDot(row.tint, label: row.stateLabel)
                    Text(row.title).fontWeight(row.node == nil ? .medium : .regular)
                    if row.node == nil, row.cluster.sharedImageStore == true {
                        Image(systemName: "shippingbox").font(.caption).foregroundStyle(.secondary)
                            .help("Shared image store: nodes can use the images on this Mac")
                            .accessibilityLabel("shared image store")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    row.node == nil ? "Cluster \(row.title), \(row.stateLabel)" : "Node \(row.title), \(row.stateLabel)"
                )
            }
            .width(min: 140, ideal: 200)
            TableColumn("Nodes") { row in
                Text(row.node?.role ?? "\(row.cluster.nodes.count)").monospacedDigit()
            }
            .width(min: 44, ideal: 60)
            TableColumn("State") { row in Text(row.stateLabel).lineLimit(1).help(row.stateLabel) }
                .width(min: 120, ideal: 150)
            TableColumn("Kubernetes") { row in
                Text(row.node == nil ? (row.cluster.kubernetesVersion ?? emDash) : "").monospacedDigit()
            }
            .width(min: 84, ideal: 90)
            TableColumn("CPUs") { row in Text(row.cpus > 0 ? "\(row.cpus)" : emDash).monospacedDigit() }
                .width(45)
            TableColumn("Memory") { row in
                Text(row.memoryMB > 0 ? ByteCount.format(row.memoryMB << 20) : emDash).monospacedDigit()
            }
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
                if capabilities.supportsLoadImage { Button("Load Image…") { loadInto = names[0] } }
                Button("Copy kubectl Context") { copyToPasteboard(KubectlCommands.context(names[0])) }
                Button("Copy “get nodes” Command") {
                    copyToPasteboard("\(KubectlCommands.context(names[0])) get nodes")
                }
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
            // container 1.7 dropped `load-image`; clusters created with the shared image store need none.
            if capabilities.supportsLoadImage {
                ToolbarActionButton("Load Image", systemImage: "square.and.arrow.down.on.square") {
                    loadInto = selectedNames.first
                }
                .disabled(selectedNames.count != 1)
            }
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
                EmptyStateView(
                    symbol: "helm", title: "No clusters",
                    message:
                        "Create a local Kubernetes cluster. The first one downloads the node image (about 1 GB) and takes a few minutes.",
                    actionTitle: "New Cluster…"
                ) { showCreate = true }
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
    /// Green when everything is up, orange for a degraded cluster (some nodes down), grey otherwise.
    var tint: Color {
        if let node { return node.state == .running ? .statusRunning : .statusStopped }
        return cluster.state.tint
    }
    /// A node's state, or the cluster's: `Running`, `Stopped`, `Unknown`, `Degraded (2 of 3 up)`.
    var stateLabel: String { node?.state.displayName ?? cluster.stateTitle }
    var cpus: Int { node?.cpus ?? cluster.nodes.reduce(0) { $0 + $1.cpus } }
    var memoryMB: Int64 { node?.memoryMB ?? cluster.nodes.reduce(0) { $0 + $1.memoryMB } }
    var address: String? {
        node?.address ?? cluster.nodes.first { $0.role.contains("control") }?.address ?? cluster.nodes.first?.address
    }
}

extension KubernetesClusterState {
    /// Status colour: green running, orange degraded, grey stopped or unknown.
    var tint: Color {
        switch self {
        case .running: return .statusRunning
        case .degraded: return .statusWarning
        case .stopped, .unknown: return .statusStopped
        }
    }
}

/// Wraps a name so it can drive `.sheet(item:)`.
struct IdentifiedName: Identifiable { let id: String }

#Preview("Kubernetes") {
    KubernetesListView()
        .appModelEnvironment(ResourcePreview.model())
        .frame(width: 1100, height: 600)
}
