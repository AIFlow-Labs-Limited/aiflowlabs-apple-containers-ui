import Foundation
import Observation
import ContainerKit

/// Networks + attached containers.
@MainActor
@Observable
public final class NetworksStore: PollingStore {
    public private(set) var items: [Network] = []
    public var isLoading = false
    public var lastError: BackendError?
    public var searchText = ""

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored private let containers: ContainersStore
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.lastError { throw error }
    }
    @ObservationIgnored private let gate: PollingGate

    public init(backend: any ContainerBackend, containers: ContainersStore, gate: PollingGate) {
        self.backend = backend
        self.containers = containers
        self.gate = gate
    }

    public var filtered: [Network] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.status?.ipv4Subnet?.contains(q) ?? false) }
    }

    /// Container ids attached to `network`.
    public func attachedContainers(_ network: Network) -> [String] {
        containers.items.filter { c in
            c.configuration.networks.contains { $0.network == network.name } || (c.status?.networks.contains { $0.network == network.name } ?? false)
        }.map(\.id)
    }

    public func refresh() async {
        guard let list = await load({ try await backend.listNetworks() }) else { return }
        items = list.sorted { ($0.isBuiltin ? 0 : 1, $0.name) < ($1.isBuiltin ? 0 : 1, $1.name) }
    }

    public func create(name: String, subnet: String? = nil, subnetV6: String? = nil, labels: [String: String] = [:]) async -> Bool {
        await perform { try await backend.createNetwork(name: name, subnet: subnet, subnetV6: subnetV6, labels: labels) }
    }

    public func delete(_ names: [String]) async {
        await perform { for name in names { try await backend.deleteNetwork(name) } }
    }

    public func prune() async { await perform { try await backend.pruneNetworks() } }
}
