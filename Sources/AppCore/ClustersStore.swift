import ContainerKit
import Foundation
import Observation

/// Local Kubernetes clusters (`container k8s`, or `container cluster` on newer CLIs). `available` is false when
/// the CLI lacks the plugin; `capabilities` says what the installed plugin can do.
@MainActor
@Observable
public final class ClustersStore: PollingStore {
    public private(set) var items: [KubernetesCluster] = []
    public private(set) var available = false
    /// What the installed plugin supports, detected by the backend from the CLI's own help. `nil` until known
    /// (and while the plugin is missing).
    public private(set) var capabilities: KubernetesCapabilities?
    public var isLoading = false
    public var loadError: BackendError?
    public var actionError: BackendError?
    /// Banner error: `actionError ?? loadError`. Setting `nil` clears both; a value becomes the `actionError`.
    public var lastError: BackendError? {
        get { actionError ?? loadError }
        set { actionError = newValue; if newValue == nil { loadError = nil } }
    }
    public var searchText = ""

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored private let tasks: TaskCenter
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.loadError { throw error }
    }
    @ObservationIgnored private let gate: PollingGate
    @ObservationIgnored private var availabilityChecked = false

    public init(backend: any ContainerBackend, tasks: TaskCenter, gate: PollingGate) {
        self.backend = backend
        self.tasks = tasks
        self.gate = gate
    }

    /// The detected capabilities, or the 1.5.0 plugin's while they are unknown (forms and previews need a value).
    public var effectiveCapabilities: KubernetesCapabilities { capabilities ?? .legacy }

    public var filtered: [KubernetesCluster] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// Lists clusters when the plugin is available.
    ///
    /// A missing plugin is remembered (errors leave it unknown and re-probe); call `recheckAvailability()` to
    /// probe again. While the plugin is available the capabilities are asked for on every refresh: the backend
    /// caches them and re-detects when the CLI binary changes, so an upgrade is picked up without a restart.
    public func refresh() async {
        if !availabilityChecked || available {
            // A thrown error (e.g. services down) means "unknown": keep the previous value and probe again next time.
            do {
                let detected = try await backend.kubernetesCapabilities()
                if capabilities != detected { capabilities = detected }
                if available != (detected != nil) { available = detected != nil }
                availabilityChecked = true
            } catch {}
        }
        guard available else {
            items = []
            loadError = nil
            return
        }
        guard let list = await load({ try await backend.listClusters() }) else { return }
        items = list.sorted { $0.name < $1.name }
    }

    /// Forgets the cached plugin availability and refreshes.
    public func recheckAvailability() async {
        invalidateAvailability()
        await refresh()
    }

    /// Forgets the cached plugin availability; the next `refresh()` probes again.
    public func invalidateAvailability() { availabilityChecked = false }

    @discardableResult
    public func create(_ spec: ClusterSpec) -> LongRunningTask {
        tasks.run(title: "Create cluster \(spec.name)", kind: .cluster, stream: backend.createCluster(spec)) {
            [weak self] _ in
            await self?.refresh()
        }
    }

    public func delete(_ names: [String]) async {
        await perform { for n in names { try await backend.deleteCluster(n) } }
    }

    @discardableResult
    public func loadImage(_ reference: String, into cluster: String?, platform: Platform? = nil) -> LongRunningTask {
        tasks.run(
            title: "Load \(reference) into \(cluster ?? "cluster")", kind: .load,
            stream: backend.loadImage(reference, intoCluster: cluster, nodes: [], platform: platform))
    }
}
