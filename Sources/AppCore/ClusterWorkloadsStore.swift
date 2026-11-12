import ContainerKit
import Foundation
import Observation

/// What runs in the cluster the Kubernetes section has selected: pods, deployments, services and nodes, read
/// with the `kubectl` inside its control-plane node.
///
/// The store follows one cluster at a time (`show(_:)`); it polls only while a view shows it and the cluster's
/// control plane is up. Namespace filtering happens here, on the one snapshot a poll returns.
@MainActor
@Observable
public final class ClusterWorkloadsStore: PollingStore {
    /// Which namespaces the tables show.
    public enum NamespaceFilter: Hashable, Sendable {
        /// Every namespace (system ones only with `showSystemNamespaces`).
        case all
        case named(String)
    }

    /// The cluster being shown.
    public private(set) var cluster: KubernetesCluster?
    /// The last snapshot; `nil` until the first one arrives and after the cluster changes.
    public private(set) var workloads: ClusterWorkloads?
    public var isLoading = false
    public var loadError: BackendError?
    public var actionError: BackendError?
    public var lastError: BackendError? {
        get { actionError ?? loadError }
        set { actionError = newValue; if newValue == nil { loadError = nil } }
    }
    public var namespaceFilter: NamespaceFilter = .all
    /// Show `kube-system` and the other namespaces the cluster runs itself in.
    public var showSystemNamespaces = false
    public var searchText = ""

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored private let gate: PollingGate
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.loadError { throw error }
    }

    public init(backend: any ContainerBackend, gate: PollingGate) {
        self.backend = backend
        self.gate = gate
    }

    // MARK: Target

    /// Where `kubectl` runs for the shown cluster; `nil` while its control plane is not running.
    public var target: KubectlTarget? { cluster?.kubectlTarget }

    /// Why there is nothing to show, when that is not an error; `nil` while workloads can be read.
    public var unavailableReason: String? {
        guard let cluster else { return "Select a cluster to see what runs in it." }
        guard cluster.kubectlTarget == nil else { return nil }
        return cluster.nodes.isEmpty
            ? "This cluster has no nodes left."
            : "The control-plane node of “\(cluster.name)” is not running, so its API server cannot be asked."
    }

    /// Follows `cluster` (or nothing). A different cluster drops the old snapshot and loads the new one; the
    /// same cluster only picks up its new state (a control plane that went down or came up).
    /// - Returns: the refresh it started, if any (tests wait for it).
    @discardableResult
    public func show(_ cluster: KubernetesCluster?) -> Task<Void, Never>? {
        let changed = cluster?.name != self.cluster?.name
        let targetChanged = cluster?.kubectlTarget != self.cluster?.kubectlTarget
        self.cluster = cluster
        guard changed || targetChanged else { return nil }
        if changed {
            workloads = nil
            namespaceFilter = .all
            clearError()
        }
        if cluster?.kubectlTarget == nil { workloads = nil }
        return Task { await refresh() }
    }

    public func refresh() async {
        guard let target else {
            workloads = nil
            loadError = nil
            return
        }
        guard let snapshot = await load({ try await backend.clusterWorkloads(target) }) else { return }
        // The selection may have moved on while kubectl ran.
        guard target == self.target else { return }
        if workloads != snapshot { workloads = snapshot }
        if case .named(let name) = namespaceFilter, !snapshot.namespaces.contains(where: { $0.name == name }) {
            namespaceFilter = .all
        }
    }

    // MARK: Filtering

    /// Namespaces offered by the picker: the user's first, then (when shown) the system ones.
    public var namespaceChoices: [String] {
        let names = (workloads?.namespaces ?? []).map(\.name)
        let user = names.filter { !KubeNamespace.isSystem($0) }.sorted()
        return showSystemNamespaces ? user + names.filter(KubeNamespace.isSystem).sorted() : user
    }

    /// Whether an object in `namespace` passes the namespace picker and the system toggle.
    public func shows(namespace: String) -> Bool {
        switch namespaceFilter {
        case .named(let name): return namespace == name
        case .all: return showSystemNamespaces || !KubeNamespace.isSystem(namespace)
        }
    }

    private func matchesSearch(_ name: String, _ namespace: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || name.localizedCaseInsensitiveContains(query)
            || namespace.localizedCaseInsensitiveContains(query)
    }

    public var pods: [KubePod] {
        (workloads?.pods ?? []).filter { shows(namespace: $0.namespace) && matchesSearch($0.name, $0.namespace) }
            .sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    public var deployments: [KubeDeployment] {
        (workloads?.deployments ?? [])
            .filter { shows(namespace: $0.namespace) && matchesSearch($0.name, $0.namespace) }
            .sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    public var services: [KubeService] {
        (workloads?.services ?? []).filter { shows(namespace: $0.namespace) && matchesSearch($0.name, $0.namespace) }
            .sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    public var nodes: [KubeNode] { (workloads?.nodes ?? []).sorted { $0.name < $1.name } }

    /// Pods hidden only because system namespaces are off (for the "n hidden" hint).
    public var hiddenSystemPodCount: Int {
        guard !showSystemNamespaces, namespaceFilter == .all else { return 0 }
        return (workloads?.pods ?? []).count { KubeNamespace.isSystem($0.namespace) }
    }

    /// The current version of a pod the user is looking at (it changes with every poll); `nil` once it is gone.
    public func pod(id: KubePod.ID) -> KubePod? { workloads?.pods.first { $0.id == id } }

    // MARK: Actions

    /// The exact command an action runs, for confirmations and "Copy Command"; `nil` without a running cluster.
    public func command(for action: KubectlAction) -> String? { target.map { action.displayCommand(in: $0) } }

    private func requireTarget() throws -> KubectlTarget {
        guard let target else {
            throw BackendError.unsupported(
                feature: "Workloads", reason: unavailableReason ?? "the cluster is not running.")
        }
        return target
    }

    /// Deletes one pod. A deployment's pod is replaced by a new one.
    @discardableResult
    public func deletePod(_ pod: KubePod) async -> Bool {
        await perform {
            try await backend.deletePod(try requireTarget(), namespace: pod.namespace, name: pod.name)
        }
    }

    /// Restarts a deployment's pods one by one (`kubectl rollout restart`).
    @discardableResult
    public func restart(_ deployment: KubeDeployment) async -> Bool {
        await perform {
            try await backend.restartDeployment(
                try requireTarget(), namespace: deployment.namespace, name: deployment.name)
        }
    }

    /// Sets a deployment's replica count.
    @discardableResult
    public func scale(_ deployment: KubeDeployment, to replicas: Int) async -> Bool {
        await perform {
            try await backend.scaleDeployment(
                try requireTarget(), namespace: deployment.namespace, name: deployment.name, replicas: replicas)
        }
    }

    /// Events about `pod`, oldest first.
    public func events(for pod: KubePod) async throws -> [KubeEvent] {
        try await backend.podEvents(try requireTarget(), namespace: pod.namespace, pod: pod.name)
    }

    /// A pod's log stream; fails at once when the cluster is not running.
    public func logs(for pod: KubePod, options: PodLogOptions) -> LineStream {
        guard let target else {
            let error = BackendError.unsupported(
                feature: "Workloads", reason: unavailableReason ?? "the cluster is not running.")
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return backend.podLogs(target, namespace: pod.namespace, pod: pod.name, options: options)
    }
}
