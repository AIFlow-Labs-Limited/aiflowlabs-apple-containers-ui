import AppCore
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// Inspector for one cluster: state, Kubernetes version, nodes, how local images reach it, and copyable commands.
struct ClusterDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let cluster: KubernetesCluster
    /// What the installed CLI's Kubernetes plugin supports (decides "Load Image" vs the shared image store).
    var capabilities: KubernetesCapabilities = .legacy
    let onLoadImage: () -> Void
    let onDelete: () -> Void

    /// The kubeconfig server is `https://<cluster>.<dns.domain>:6443`; without a macOS resolver for that domain
    /// (`container system dns create`), `kubectl --context <cluster>` fails with "no such host".
    private var unresolvedDomain: String? {
        guard let domain = model.system.properties?.dns?.domain, !domain.isEmpty else { return nil }
        return model.system.dnsDomains.contains { $0.domain == domain } ? nil : domain
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack(spacing: Spacing.s) {
                    StatusDot(cluster.state.tint, size: 10, label: cluster.stateTitle)
                    Text(cluster.name).font(.title3.bold()).textSelection(.enabled)
                    TagBadge("Experimental", tint: .statusWarning)
                    if cluster.sharedImageStore == true {
                        TagBadge("Shared image store", tint: .accentColor)
                            .help("Nodes can use the images in this Mac's image store")
                    }
                    Spacer()
                }
                HStack {
                    if capabilities.supportsLoadImage {
                        Button("Load Image…", systemImage: "square.and.arrow.down.on.square", action: onLoadImage)
                    }
                    Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
                }
                InspectorSection("Cluster") { KeyValueGrid(summary) }
                InspectorSection("Nodes") { ClusterNodesGrid(nodes: cluster.nodes) }
                InspectorSection("kubectl") {
                    CopyableCommandRow(title: "Context", command: KubectlCommands.context(cluster.name))
                    Text("Added to ~/.kube/config as context “\(cluster.name)”.").font(.caption).foregroundStyle(
                        .secondary)
                }
                if let domain = unresolvedDomain {
                    let host = cluster.fqdn ?? "\(cluster.name).\(domain)"
                    InfoCard(
                        title: "kubectl can't reach \(host) yet", symbol: "exclamationmark.triangle",
                        tint: .statusWarning
                    ) {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text(
                                "The context points at https://\(host):6443, but this Mac has no resolver "
                                    + "for “.\(domain)”, so kubectl fails with “no such host”. Enable DNS names once "
                                    + "(administrator password)."
                            )
                            Button("Set up DNS names…") {
                                UserDefaults.standard.set("network", forKey: SettingsView.selectedTabKey)
                                openSettings()
                            }
                            .accessibilityHint("Opens Settings, Network")
                        }
                    }
                }
                imagesCard
                stoppedCard
                InspectorSection("Quick commands") {
                    ForEach(KubectlCommands.quick(cluster.name, capabilities: capabilities), id: \.command) { item in
                        CopyableCommandRow(title: item.title, command: item.command)
                    }
                }
            }
            .padding(Spacing.l)
        }
    }

    /// Facts the CLI reports about the cluster; rows it does not report (older CLIs) are left out.
    private var summary: [(String, String)] {
        var rows: [(String, String)] = [("State", cluster.stateTitle)]
        if let version = cluster.kubernetesVersion { rows.append(("Kubernetes", version)) }
        rows.append(("Nodes", cluster.nodesSummary))
        if let shared = cluster.sharedImageStore { rows.append(("Shared image store", shared ? "On" : "Off")) }
        if cluster.kubernetesVersion != nil { rows.append(("CNI", cluster.cniTitle)) }
        if let fqdn = cluster.fqdn { rows.append(("API server", "https://\(fqdn):6443")) }
        if let created = cluster.creationDate { rows.append(("Created", RelativeDate.format(created))) }
        return rows
    }

    /// How local images get into this cluster: `load-image` (CLIs up to 1.6) or the shared image store (1.7+).
    @ViewBuilder
    private var imagesCard: some View {
        if capabilities.supportsLoadImage {
            InfoCard(title: "Images loaded", symbol: "shippingbox") {
                Text(
                    "Load image copies a local image into every node's containerd (namespace k8s.io). Reference it by the same name with `imagePullPolicy: Never` (or `IfNotPresent`) so the kubelet doesn't try to pull it."
                )
            }
        } else if cluster.sharedImageStore == true {
            InfoCard(title: "Uses the images on this Mac", symbol: "shippingbox") {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(SharedImageStoreNotes.usage)
                    ForEach(SharedImageStoreNotes.warnings, id: \.self) { Bullet(LocalizedStringKey($0)) }
                }
            }
        } else if capabilities.supportsSharedImageStore {
            InfoCard(title: "Local images aren't shared with this cluster", symbol: "shippingbox") {
                Text(SharedImageStoreNotes.off)
            }
        }
    }

    @ViewBuilder
    private var stoppedCard: some View {
        if !cluster.isRunning, !cluster.nodes.isEmpty {
            InfoCard(
                title: "Stopped clusters can't be restarted", symbol: "exclamationmark.triangle",
                tint: .statusWarning
            ) {
                Text(
                    cluster.removeOnStop == true
                        ? "This cluster was created to delete itself when it stops: its nodes are gone and only the "
                            + "record is left. Delete it to clear the record."
                        : "A stopped control-plane node doesn't come back. Delete the cluster and create it again.")
            }
        }
    }
}

/// Node table of the inspector: name, role, state, size and address (ports under the address).
struct ClusterNodesGrid: View {
    let nodes: [KubernetesCluster.Node]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
            GridRow {
                ForEach(["Node", "Role", "State", "Size", "Address"], id: \.self) {
                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(nodes) { node in
                GridRow {
                    Text(node.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Text(node.role).font(.callout).lineLimit(2)
                    HStack(spacing: Spacing.xxs) {
                        StatusDot(node.state == .running ? .statusRunning : .statusStopped, size: 6)
                        Text(node.state.displayName).font(.callout).lineLimit(1).fixedSize()
                    }
                    Text(node.sizeText ?? emDash).font(.callout).monospacedDigit().lineLimit(1).fixedSize()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(node.address ?? emDash).font(.callout.monospaced()).lineLimit(1).fixedSize()
                            .textSelection(.enabled)
                        if let ports = node.ports {
                            Text(ports).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if nodes.isEmpty {
                Text("No nodes reported.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Cluster detail, 1.5 CLI") {
    ClusterDetailView(
        cluster: KubernetesCluster(
            name: "k8s-dev",
            nodes: [
                .init(
                    name: "k8s-dev", role: "control-plane,worker", state: .running, cpus: 4, memoryMB: 4096,
                    address: "192.168.64.70", ports: "6443->6443")
            ]), onLoadImage: {}, onDelete: {}
    )
    .frame(width: 420, height: 700)
    .appModelEnvironment(ResourcePreview.model())
}

#Preview("Cluster detail, 1.7 CLI, degraded") {
    ClusterDetailView(
        cluster: ((try? DerivedFixtures.clusters()) ?? []).first { $0.name == "staging" }
            ?? KubernetesCluster(name: "staging", nodes: []),
        capabilities: .modern, onLoadImage: {}, onDelete: {}
    )
    .frame(width: 460, height: 800)
    .appModelEnvironment(ResourcePreview.model())
}
