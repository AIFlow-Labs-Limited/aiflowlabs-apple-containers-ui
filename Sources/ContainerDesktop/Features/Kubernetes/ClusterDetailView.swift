import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// Inspector for one cluster: nodes, how loaded images work, and copyable kubectl commands.
struct ClusterDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let cluster: KubernetesCluster
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
                    StatusDot(
                        cluster.isRunning ? .statusRunning : .statusStopped, size: 10,
                        label: cluster.isRunning ? "Running" : "Stopped")
                    Text(cluster.name).font(.title3.bold()).textSelection(.enabled)
                    TagBadge("Experimental", tint: .statusWarning)
                    Spacer()
                }
                HStack {
                    Button("Load Image…", systemImage: "square.and.arrow.down.on.square", action: onLoadImage)
                    Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
                }
                InspectorSection("Nodes") { nodesGrid }
                InspectorSection("kubectl") {
                    CopyableCommandRow(title: "Context", command: KubectlCommands.context(cluster.name))
                    Text("Added to ~/.kube/config as context “\(cluster.name)”.").font(.caption).foregroundStyle(
                        .secondary)
                }
                if let domain = unresolvedDomain {
                    InfoCard(
                        title: "kubectl can't reach \(cluster.name).\(domain) yet", symbol: "exclamationmark.triangle",
                        tint: .statusWarning
                    ) {
                        VStack(alignment: .leading, spacing: Spacing.s) {
                            Text(
                                "The context points at https://\(cluster.name).\(domain):6443, but this Mac has no resolver "
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
                InfoCard(title: "Images loaded", symbol: "shippingbox") {
                    Text(
                        "Load image copies a local image into every node's containerd (namespace k8s.io). Reference it by the same name with `imagePullPolicy: Never` (or `IfNotPresent`) so the kubelet doesn't try to pull it."
                    )
                }
                if !cluster.isRunning, !cluster.nodes.isEmpty {
                    InfoCard(
                        title: "Stopped clusters can't be restarted", symbol: "exclamationmark.triangle",
                        tint: .statusWarning
                    ) {
                        Text("A stopped control-plane node doesn't come back. Delete the cluster and create it again.")
                    }
                }
                InspectorSection("Quick commands") {
                    ForEach(KubectlCommands.quick(cluster.name), id: \.command) { item in
                        CopyableCommandRow(title: item.title, command: item.command)
                    }
                }
            }
            .padding(Spacing.l)
        }
    }

    private var nodesGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.m, verticalSpacing: Spacing.s) {
            GridRow {
                ForEach(["Node", "Role", "State", "Address", "Ports"], id: \.self) {
                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(cluster.nodes) { node in
                GridRow {
                    Text(node.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Text(node.role).font(.callout).lineLimit(1).fixedSize()
                    HStack(spacing: Spacing.xxs) {
                        StatusDot(node.state == .running ? .statusRunning : .statusStopped, size: 6)
                        Text(node.state.displayName).font(.callout).lineLimit(1).fixedSize()
                    }
                    Text(node.address ?? emDash).font(.callout.monospaced()).lineLimit(1).fixedSize().textSelection(
                        .enabled)
                    Text(node.ports ?? emDash).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            if cluster.nodes.isEmpty {
                Text("No nodes reported.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Cluster detail") {
    ClusterDetailView(
        cluster: KubernetesCluster(
            name: "k8s-dev",
            nodes: [
                .init(
                    name: "k8s-dev-control-plane", role: "control-plane", state: .running, cpus: 4, memoryMB: 4096,
                    address: "192.168.64.70", ports: "6443->6443")
            ]), onLoadImage: {}, onDelete: {}
    )
    .frame(width: 420, height: 700)
    .appModelEnvironment(ResourcePreview.model())
}
