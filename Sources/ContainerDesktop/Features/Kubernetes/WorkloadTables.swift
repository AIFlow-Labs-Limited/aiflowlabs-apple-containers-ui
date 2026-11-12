import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

// The four tables of the workloads view. Columns follow `kubectl get … -o wide`, which is also what Docker
// Desktop's and Lens's lists show.

extension KubePodHealth {
    /// Green healthy, orange in between, red failing, grey done.
    var tint: Color {
        switch self {
        case .healthy: return .statusRunning
        case .progressing: return .statusWarning
        case .failing: return .statusError
        case .completed: return .statusStopped
        }
    }
}

/// An age that keeps counting between polls (`4m19s`), with the creation time as tooltip.
struct AgeText: View {
    let date: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            Text(KubeAge.format(since: date, now: context.date) ?? emDash).monospacedDigit()
        }
        .help(date.map(RelativeDate.absolute) ?? "")
    }
}

/// Pods: name, namespace, ready, status (with the reason for a crash loop or a failed pull), restarts, age, node.
struct PodsTable: View {
    let pods: [KubePod]
    @Binding var selection: Set<KubePod.ID>
    let open: (KubePod, PodDetailTab) -> Void
    let delete: (KubePod) -> Void
    let copyCommand: (KubectlAction) -> Void

    var body: some View {
        Table(pods, selection: $selection) {
            TableColumn("Name") { pod in
                HStack(spacing: Spacing.xs) {
                    StatusDot(pod.health.tint, label: pod.statusText)
                    Text(pod.name).lineLimit(1).truncationMode(.middle).help(pod.name)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pod \(pod.name), \(pod.statusText)")
            }
            .width(min: 160, ideal: 240)
            TableColumn("Namespace") { pod in Text(pod.namespace).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 70, ideal: 100)
            TableColumn("Ready") { pod in Text(pod.readyText).monospacedDigit() }
                .width(46)
            TableColumn("Status") { pod in
                Text(pod.statusText)
                    .foregroundStyle(pod.health == .failing ? AnyShapeStyle(.statusError) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .help(pod.statusMessage ?? pod.statusText)
            }
            .width(min: 90, ideal: 140)
            TableColumn("Restarts") { pod in
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text(pod.restartsText(now: context.date)).monospacedDigit().lineLimit(1)
                }
            }
            .width(min: 56, ideal: 120)
            TableColumn("Age") { pod in AgeText(date: pod.metadata.creationTimestamp) }
                .width(min: 44, ideal: 60)
            TableColumn("Node") { pod in
                Text(pod.nodeName ?? emDash).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 80, ideal: 150)
        }
        .contextMenu(forSelectionType: KubePod.ID.self) { ids in
            if let pod = pods.first(where: { ids.contains($0.id) }), ids.count == 1 {
                Button("Show Details") { open(pod, .overview) }
                Button("Show Logs") { open(pod, .logs) }
                Divider()
                Button("Copy Logs Command") {
                    copyCommand(.logs(namespace: pod.namespace, pod: pod.name, options: PodLogOptions(follow: true)))
                }
                Button("Copy Delete Command") { copyCommand(.deletePod(namespace: pod.namespace, name: pod.name)) }
                Divider()
                Button("Delete Pod…", role: .destructive) { delete(pod) }
            }
        } primaryAction: { ids in
            if let pod = pods.first(where: { ids.contains($0.id) }) { open(pod, .overview) }
        }
    }
}

/// Deployments: ready / up-to-date / available and age.
struct DeploymentsTable: View {
    let deployments: [KubeDeployment]
    @Binding var selection: Set<KubeDeployment.ID>
    let restart: (KubeDeployment) -> Void
    let scale: (KubeDeployment) -> Void
    let copyCommand: (KubectlAction) -> Void

    var body: some View {
        Table(deployments, selection: $selection) {
            TableColumn("Name") { deployment in
                HStack(spacing: Spacing.xs) {
                    StatusDot(
                        deployment.isSettled ? .statusRunning : .statusWarning,
                        label: deployment.isSettled ? "ready" : "not all pods ready")
                    Text(deployment.name).lineLimit(1).truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
            }
            .width(min: 160, ideal: 240)
            TableColumn("Namespace") { deployment in
                Text(deployment.namespace).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 70, ideal: 110)
            TableColumn("Ready") { deployment in Text(deployment.readyText).monospacedDigit() }
                .width(min: 46, ideal: 60)
            TableColumn("Up-to-date") { deployment in Text("\(deployment.updatedReplicas)").monospacedDigit() }
                .width(min: 66, ideal: 80)
            TableColumn("Available") { deployment in Text("\(deployment.availableReplicas)").monospacedDigit() }
                .width(min: 60, ideal: 80)
            TableColumn("Age") { deployment in AgeText(date: deployment.metadata.creationTimestamp) }
                .width(min: 44, ideal: 70)
        }
        .contextMenu(forSelectionType: KubeDeployment.ID.self) { ids in
            if let deployment = deployments.first(where: { ids.contains($0.id) }), ids.count == 1 {
                Button("Scale…") { scale(deployment) }
                Button("Restart…") { restart(deployment) }
                Divider()
                Button("Copy Restart Command") {
                    copyCommand(.restartDeployment(namespace: deployment.namespace, name: deployment.name))
                }
                Button("Copy Scale Command") {
                    copyCommand(
                        .scaleDeployment(
                            namespace: deployment.namespace, name: deployment.name,
                            replicas: deployment.desiredReplicas))
                }
            }
        } primaryAction: { ids in
            if let deployment = deployments.first(where: { ids.contains($0.id) }) { scale(deployment) }
        }
    }
}

/// Services: type, cluster IP, external address and ports.
struct ServicesTable: View {
    let services: [KubeService]
    @State private var selection = Set<KubeService.ID>()

    var body: some View {
        Table(services, selection: $selection) {
            TableColumn("Name") { service in Text(service.name).lineLimit(1).truncationMode(.middle) }
                .width(min: 140, ideal: 220)
            TableColumn("Namespace") { service in Text(service.namespace).foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 70, ideal: 110)
            TableColumn("Type") { service in Text(service.type).lineLimit(1) }
                .width(min: 70, ideal: 100)
            TableColumn("Cluster IP") { service in
                Text(service.spec?.clusterIP ?? emDash).font(.monoCaption).textSelection(.enabled)
            }
            .width(min: 90, ideal: 120)
            TableColumn("External") { service in
                Text(service.externalText ?? emDash).font(.monoCaption).foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
            TableColumn("Ports") { service in
                Text(service.portsText.isEmpty ? emDash : service.portsText).font(.monoCaption).lineLimit(1)
                    .help(service.portsText)
            }
            .width(min: 90, ideal: 170)
            TableColumn("Age") { service in AgeText(date: service.metadata.creationTimestamp) }
                .width(min: 44, ideal: 60)
        }
        .contextMenu(forSelectionType: KubeService.ID.self) { ids in
            if let service = services.first(where: { ids.contains($0.id) }), let ip = service.spec?.clusterIP {
                Button("Copy Cluster IP") { copyToPasteboard(ip) }
            }
        }
    }
}

/// Nodes as Kubernetes reports them: readiness, roles, kubelet version, address.
struct KubeNodesTable: View {
    let nodes: [KubeNode]
    @State private var selection = Set<KubeNode.ID>()

    var body: some View {
        Table(nodes, selection: $selection) {
            TableColumn("Name") { node in
                HStack(spacing: Spacing.xs) {
                    StatusDot(node.isReady ? .statusRunning : .statusError, label: node.statusText)
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                }
                .accessibilityElement(children: .combine)
            }
            .width(min: 160, ideal: 240)
            TableColumn("Status") { node in Text(node.statusText).lineLimit(1) }
                .width(min: 70, ideal: 110)
            TableColumn("Roles") { node in Text(node.rolesText).lineLimit(1) }
                .width(min: 80, ideal: 120)
            TableColumn("Version") { node in
                Text(node.status?.nodeInfo?.kubeletVersion ?? emDash).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Internal IP") { node in
                Text(node.internalIP ?? emDash).font(.monoCaption).textSelection(.enabled)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Runtime") { node in
                Text(node.status?.nodeInfo?.containerRuntimeVersion ?? emDash).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 150)
            TableColumn("Age") { node in AgeText(date: node.metadata.creationTimestamp) }
                .width(min: 44, ideal: 60)
        }
    }
}
