import ContainerKit
import Foundation

// `ContainerFileOperations` and `container clean` for the two wrapper backends (kept out of their main files, which every
// backend change touches).

extension SwitchableBackend {
    public func listDirectory(_ id: String, path: String, limit: Int) async throws -> ContainerDirectoryListing {
        try await current.listDirectory(id, path: path, limit: limit)
    }
    public func readFile(_ id: String, path: String, maxBytes: Int) async throws -> Data {
        try await current.readFile(id, path: path, maxBytes: maxBytes)
    }
    public func makeDirectory(_ id: String, path: String) async throws {
        try await current.makeDirectory(id, path: path)
    }
    public func moveItem(_ id: String, from source: String, to destination: String) async throws {
        try await current.moveItem(id, from: source, to: destination)
    }
    public func deleteItem(_ id: String, path: String) async throws {
        try await current.deleteItem(id, path: path)
    }
    public func copyOut(_ id: String, path: String, to localPath: String) async throws {
        try await current.copyOut(id, path: path, to: localPath)
    }
    public func copyIn(_ id: String, localPath: String, to path: String) async throws {
        try await current.copyIn(id, localPath: localPath, to: path)
    }
    public func supportsCommit() async -> Bool {
        await current.supportsCommit()
    }
    public func commitContainer(_ id: String, reference: String) -> LineStream {
        current.commitContainer(id, reference: reference)
    }
    public func supportsClean() async -> Bool {
        await current.supportsClean()
    }
    public func cleanContainers(_ ids: [String]) -> LineStream {
        current.cleanContainers(ids)
    }
}

extension UnavailableBackend {
    private var notInstalled: BackendError { .cliNotInstalled(searchedPaths: searchedPaths) }

    public func listDirectory(_ id: String, path: String, limit: Int) async throws -> ContainerDirectoryListing {
        throw notInstalled
    }
    public func readFile(_ id: String, path: String, maxBytes: Int) async throws -> Data { throw notInstalled }
    public func makeDirectory(_ id: String, path: String) async throws { throw notInstalled }
    public func moveItem(_ id: String, from source: String, to destination: String) async throws {
        throw notInstalled
    }
    public func deleteItem(_ id: String, path: String) async throws { throw notInstalled }
    public func copyOut(_ id: String, path: String, to localPath: String) async throws { throw notInstalled }
    public func copyIn(_ id: String, localPath: String, to path: String) async throws { throw notInstalled }
    public func supportsCommit() async -> Bool { false }
    public func commitContainer(_ id: String, reference: String) -> LineStream {
        let error = notInstalled
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    public func supportsClean() async -> Bool { false }
    public func cleanContainers(_ ids: [String]) -> LineStream {
        let error = notInstalled
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
}

// `KubernetesWorkloadOperations` for the same two wrappers.

extension SwitchableBackend {
    public func clusterWorkloads(_ target: KubectlTarget) async throws -> ClusterWorkloads {
        try await current.clusterWorkloads(target)
    }
    public func podEvents(_ target: KubectlTarget, namespace: String, pod: String) async throws -> [KubeEvent] {
        try await current.podEvents(target, namespace: namespace, pod: pod)
    }
    public func podLogs(
        _ target: KubectlTarget, namespace: String, pod: String, options: PodLogOptions
    ) -> LineStream {
        current.podLogs(target, namespace: namespace, pod: pod, options: options)
    }
    public func deletePod(_ target: KubectlTarget, namespace: String, name: String) async throws {
        try await current.deletePod(target, namespace: namespace, name: name)
    }
    public func restartDeployment(_ target: KubectlTarget, namespace: String, name: String) async throws {
        try await current.restartDeployment(target, namespace: namespace, name: name)
    }
    public func scaleDeployment(
        _ target: KubectlTarget, namespace: String, name: String, replicas: Int
    ) async throws {
        try await current.scaleDeployment(target, namespace: namespace, name: name, replicas: replicas)
    }
}

extension UnavailableBackend {
    public func clusterWorkloads(_ target: KubectlTarget) async throws -> ClusterWorkloads { throw notInstalled }
    public func podEvents(_ target: KubectlTarget, namespace: String, pod: String) async throws -> [KubeEvent] {
        throw notInstalled
    }
    public func podLogs(
        _ target: KubectlTarget, namespace: String, pod: String, options: PodLogOptions
    ) -> LineStream {
        let error = notInstalled
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    public func deletePod(_ target: KubectlTarget, namespace: String, name: String) async throws {
        throw notInstalled
    }
    public func restartDeployment(_ target: KubectlTarget, namespace: String, name: String) async throws {
        throw notInstalled
    }
    public func scaleDeployment(
        _ target: KubectlTarget, namespace: String, name: String, replicas: Int
    ) async throws { throw notInstalled }
}
