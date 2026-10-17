import Foundation
import Observation
import ContainerKit

/// Local images, "in use" detection from containers, and pull/push/tag/delete/prune.
@MainActor
@Observable
public final class ImagesStore: PollingStore {
    public private(set) var items: [Image] = []
    public var isLoading = false
    public var lastError: BackendError?
    public var searchText = ""

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored private let containers: ContainersStore
    @ObservationIgnored private let tasks: TaskCenter
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.lastError { throw error }
    }
    @ObservationIgnored private let gate: PollingGate

    public init(backend: any ContainerBackend, containers: ContainersStore, tasks: TaskCenter, gate: PollingGate) {
        self.backend = backend
        self.containers = containers
        self.tasks = tasks
        self.gate = gate
    }

    /// Image references used by any container (running or not).
    public var inUseReferences: Set<String> { Set(containers.items.map(\.imageReference)) }

    public func isInUse(_ image: Image) -> Bool { inUseReferences.contains(image.reference) }

    /// Containers that use `image`.
    public func containers(using image: Image) -> [Container] {
        containers.items.filter { $0.imageReference == image.reference }
    }

    public var filtered: [Image] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.reference.localizedCaseInsensitiveContains(q) || $0.id.hasPrefix(q.lowercased()) }
    }

    public var totalSize: Int64 { items.reduce(0) { $0 + $1.totalSize } }

    public func image(id: String) -> Image? { items.first { $0.id == id || $0.reference == id } }

    public func refresh() async {
        guard let list = await load({ try await backend.listImages() }) else { return }
        items = list.sorted { $0.reference.localizedStandardCompare($1.reference) == .orderedAscending }
    }

    /// Streams `container image pull` into the Activity panel; refreshes when done.
    @discardableResult
    public func pull(_ reference: String, platform: Platform? = nil) -> LongRunningTask {
        tasks.run(title: "Pull \(reference)", kind: .pull, stream: backend.pullImage(reference, platform: platform)) { [weak self] _ in
            await self?.refresh()
        }
    }

    @discardableResult
    public func push(_ reference: String, platform: Platform? = nil) -> LongRunningTask {
        tasks.run(title: "Push \(reference)", kind: .push, stream: backend.pushImage(reference, platform: platform))
    }

    public func delete(_ references: [String]) async {
        await perform { for ref in references { try await backend.deleteImage(ref) } }
    }

    public func tag(_ reference: String, as newReference: String) async {
        await perform { try await backend.tagImage(reference, newReference: newReference) }
    }

    /// `all == false` removes dangling images only.
    public func prune(all: Bool) async { await perform { try await backend.pruneImages(all: all) } }

    public func save(_ references: [String], to path: String, platform: Platform? = nil) async {
        await perform { try await backend.saveImages(references, to: path, platform: platform) }
    }

    public func load(from path: String) async { await perform { try await backend.loadImages(from: path) } }
}
