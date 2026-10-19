import Foundation
import Observation
import ContainerKit

/// Volumes + which containers mount them.
@MainActor
@Observable
public final class VolumesStore: PollingStore {
    public private(set) var items: [Volume] = []
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
    @ObservationIgnored private let containers: ContainersStore
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.loadError { throw error }
    }
    @ObservationIgnored private let gate: PollingGate

    public init(backend: any ContainerBackend, containers: ContainersStore, gate: PollingGate) {
        self.backend = backend
        self.containers = containers
        self.gate = gate
    }

    public var filtered: [Volume] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// Container ids mounting `volume`.
    public func usedBy(_ volume: Volume) -> [String] {
        ResourceUsage.containers(mounting: volume, in: containers.items).map(\.id)
    }

    public func refresh() async {
        guard let list = await load({ try await backend.listVolumes() }) else { return }
        items = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func create(name: String, size: MemorySize? = nil, journal: String? = nil, labels: [String: String] = [:]) async -> Bool {
        await perform { try await backend.createVolume(name: name, size: size, journal: journal, labels: labels) }
    }

    public func delete(_ names: [String]) async {
        await perform { for name in names { try await backend.deleteVolume(name) } }
    }

    public func prune() async { await perform { try await backend.pruneVolumes() } }
}
