import AppCore
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// Which pod the detail sheet shows, and on which tab it opens.
struct PodRoute: Identifiable, Hashable {
    let id: KubePod.ID
    var tab: PodDetailTab
}

/// What runs in a cluster: Pods, Deployments, Services and Nodes with a namespace picker, pod details and logs,
/// and delete / restart / scale. Everything goes through `ClusterWorkloadsStore`, which runs the `kubectl`
/// inside the cluster's control-plane node; the view polls only while it is on screen.
struct ClusterWorkloadsView: View {
    @Environment(AppModel.self) private var model
    let cluster: KubernetesCluster

    @State private var kind = WorkloadKind.pods
    @State private var podSelection = Set<KubePod.ID>()
    @State private var deploymentSelection = Set<KubeDeployment.ID>()
    @State private var route: PodRoute?
    @State private var pendingDelete: KubePod?
    @State private var pendingRestart: KubeDeployment?
    @State private var scaling: KubeDeployment?
    #if DEBUG
        @State private var debugOpen: PodDetailTab?
    #endif

    private var store: ClusterWorkloadsStore { model.workloads }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .storeChrome(store)
        .onChange(of: cluster, initial: true) { store.show(cluster) }
        .sheet(item: $route) { route in
            PodDetailSheet(route: route) { pod in
                self.route = nil
                pendingDelete = pod
            }
        }
        .sheet(item: $scaling) { deployment in
            ScaleDeploymentSheet(deployment: deployment, command: { command(.scale($0, deployment)) }) { replicas in
                Task {
                    if await store.scale(deployment, to: replicas) {
                        model.toasts.success("Scaled \(deployment.name) to \(replicas)")
                    }
                }
            }
        }
        .confirmDestructive(
            title: "Delete pod “\(pendingDelete?.name ?? "")”?",
            message: pendingDelete.map(deleteMessage) ?? "",
            actionTitle: "Delete Pod",
            isPresented: presence($pendingDelete)
        ) { [pod = pendingDelete] in
            guard let pod else { return }
            Task {
                if await store.deletePod(pod) { model.toasts.success("Deleted pod \(pod.name)") }
                podSelection.remove(pod.id)
            }
        }
        .alert(
            "Restart deployment “\(pendingRestart?.name ?? "")”?", isPresented: presence($pendingRestart),
            presenting: pendingRestart
        ) { deployment in
            Button("Restart") {
                Task {
                    if await store.restart(deployment) { model.toasts.success("Restarting \(deployment.name)") }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { deployment in
            Text(
                "Replaces the \(deployment.desiredReplicas) pod\(deployment.desiredReplicas == 1 ? "" : "s") of "
                    + "“\(deployment.name)” in namespace “\(deployment.namespace)” one by one.\n\n"
                    + command(.restart(deployment)))
        }
        #if DEBUG
            .debugHook("workload-pod") { debugOpen = .overview }
            .debugHook("workload-logs") { debugOpen = .logs }
            .onChange(of: store.pods.isEmpty, initial: true) { openDebugPod() }
            .onChange(of: debugOpen) { openDebugPod() }
        #endif
    }

    // MARK: Header

    private var header: some View {
        @Bindable var store = store
        return HStack(spacing: Spacing.s) {
            Picker("Kind", selection: $kind) {
                ForEach(WorkloadKind.allCases) { kind in
                    Text(store.workloads == nil ? kind.title : "\(kind.title) \(store.count(of: kind))").tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if let trouble = store.troubleSummary {
                Label(trouble, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.statusError).lineLimit(1).fixedSize()
            }
            Spacer(minLength: Spacing.s)
            if store.isLoading { ProgressView().controlSize(.small).help("Asking the cluster") }
            if kind != .nodes { namespaceMenu }
            SearchField(text: $store.searchText, prompt: "Filter").frame(width: 150)
        }
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .background(.bar)
    }

    /// "My namespaces" (system ones hidden), "All namespaces", or one namespace.
    private var namespaceMenu: some View {
        let names = (store.workloads?.namespaces ?? []).map(\.name).sorted()
        return Menu {
            Button("My Namespaces") { choose(.all, system: false) }
            Button("All Namespaces, with System") { choose(.all, system: true) }
            Divider()
            ForEach(names.filter { !KubeNamespace.isSystem($0) }, id: \.self) { name in
                Button(name) { choose(.named(name), system: store.showSystemNamespaces) }
            }
            Divider()
            ForEach(names.filter(KubeNamespace.isSystem), id: \.self) { name in
                Button(name) { choose(.named(name), system: store.showSystemNamespaces) }
            }
        } label: {
            Label(namespaceTitle, systemImage: "square.dashed")
        }
        .labelStyle(.titleAndIcon)
        .fixedSize()
        .help("Namespace. System namespaces (kube-system and the like) are hidden until you ask for them.")
        .accessibilityLabel("Namespace: \(namespaceTitle)")
    }

    private var namespaceTitle: String {
        switch store.namespaceFilter {
        case .named(let name): return name
        case .all: return store.showSystemNamespaces ? "All namespaces" : "My namespaces"
        }
    }

    private func choose(_ filter: ClusterWorkloadsStore.NamespaceFilter, system: Bool) {
        store.namespaceFilter = filter
        store.showSystemNamespaces = system
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let reason = store.unavailableReason {
            ContentUnavailableView {
                Label("Workloads aren't available", systemImage: "square.stack.3d.up.slash")
            } description: {
                Text(reason)
            }
        } else if store.workloads == nil {
            if store.lastError == nil {
                ProgressView("Asking the cluster…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Couldn't read the cluster", systemImage: "exclamationmark.triangle",
                    description: Text("See the message above. The view tries again by itself."))
            }
        } else {
            table.overlay { emptyState }
        }
    }

    @ViewBuilder
    private var table: some View {
        switch kind {
        case .pods:
            PodsTable(
                pods: store.pods, selection: $podSelection, open: { route = PodRoute(id: $0.id, tab: $1) },
                delete: { pendingDelete = $0 }, copyCommand: copy)
        case .deployments:
            DeploymentsTable(
                deployments: store.deployments, selection: $deploymentSelection,
                restart: { pendingRestart = $0 }, scale: { scaling = $0 }, copyCommand: copy)
        case .services: ServicesTable(services: store.services)
        case .nodes: KubeNodesTable(nodes: store.nodes)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.count(of: kind) == 0 {
            if !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            } else if store.hiddenSystemPodCount > 0, kind != .nodes {
                EmptyStateView(
                    symbol: "square.stack.3d.up", title: "No \(kind.title.lowercased()) of your own yet",
                    message:
                        "Nothing is deployed outside the system namespaces. Apply a manifest with kubectl, or show the \(store.hiddenSystemPodCount) system pods.",
                    actionTitle: "Show All Namespaces"
                ) { store.showSystemNamespaces = true }
            } else {
                EmptyStateView(
                    symbol: "square.stack.3d.up", title: "No \(kind.title.lowercased())",
                    message: "Nothing matches the selected namespace.")
            }
        }
    }

    /// `true` while `binding` holds a value; setting `false` clears it (drives the alerts).
    private func presence<Value>(_ binding: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { binding.wrappedValue != nil }, set: { if !$0 { binding.wrappedValue = nil } })
    }

    // MARK: Commands

    private enum CommandKind {
        case restart(KubeDeployment)
        case scale(Int, KubeDeployment)
    }

    private func command(_ kind: CommandKind) -> String {
        switch kind {
        case .restart(let deployment):
            return store.command(for: .restartDeployment(namespace: deployment.namespace, name: deployment.name)) ?? ""
        case .scale(let replicas, let deployment):
            return store.command(
                for: .scaleDeployment(namespace: deployment.namespace, name: deployment.name, replicas: replicas))
                ?? ""
        }
    }

    private func copy(_ action: KubectlAction) {
        guard let command = store.command(for: action) else { return }
        copyToPasteboard(command)
        model.toasts.info("Copied command", message: command)
    }

    /// Names the pod, says whether something replaces it, and shows the command.
    private func deleteMessage(_ pod: KubePod) -> String {
        let consequence =
            pod.ownerName == nil
            ? "Nothing manages this pod, so it will not come back."
            : "It is managed by “\(pod.ownerName ?? "")”, which starts a replacement."
        let command = store.command(for: .deletePod(namespace: pod.namespace, name: pod.name)) ?? ""
        return "Deletes the pod “\(pod.name)” in namespace “\(pod.namespace)”. \(consequence)\n\n\(command)"
    }

    #if DEBUG
        /// Opens a pod once pods have loaded, for screenshots: the first failing one for the details, a restarted
        /// one (which has a log) for the logs.
        private func openDebugPod() {
            guard let tab = debugOpen else { return }
            let failing = store.pods.first { $0.health == .failing }
            let restarted = store.pods.first { $0.restartCount > 0 }
            guard let pod = (tab == .logs ? restarted ?? failing : failing) ?? store.pods.first else { return }
            debugOpen = nil
            route = PodRoute(id: pod.id, tab: tab)
        }
    #endif
}

#Preview("Workloads") {
    let model = AppModel(backend: MockBackend(kubernetes: .modern), observeAppActivation: false)
    ClusterWorkloadsView(
        cluster: ((try? ClusterSamples.clusters()) ?? []).first { $0.isRunning }
            ?? KubernetesCluster(name: "dev", nodes: [])
    )
    .appModelEnvironment(model)
    .frame(width: 900, height: 360)
}
