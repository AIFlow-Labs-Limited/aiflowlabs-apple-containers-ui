import ContainerKit
import Foundation

// `KubernetesWorkloadOperations` for the mock: each cluster carries the recorded sample (`MockWorkloads`) and
// changes the way a real one does when a pod is deleted or a deployment is scaled or restarted.
extension MockBackend {
    /// The cluster `target` names, which must exist and have its control-plane node running.
    private func cluster(for target: KubectlTarget, action: KubectlAction) throws -> KubernetesCluster {
        guard systemRunning else { throw BackendError.systemNotRunning }
        guard let cluster = clusters.first(where: { $0.name == target.cluster }), cluster.kubectlTarget == target
        else {
            throw BackendError.unsupported(
                feature: "Workloads of “\(target.cluster)”",
                reason: "its control-plane node “\(target.node)” is not running.")
        }
        return cluster
    }

    private func pause() async { try? await Task.sleep(for: latency) }

    private func state(of cluster: KubernetesCluster) -> ClusterWorkloads {
        if let state = workloadStates[cluster.name] { return state }
        let seeded = MockWorkloads.seed(for: cluster)
        workloadStates[cluster.name] = seeded
        return seeded
    }

    /// Replaces what runs in a cluster (tests).
    public func setWorkloads(_ workloads: ClusterWorkloads, cluster: String) { workloadStates[cluster] = workloads }

    /// Replaces the clusters the mock has (tests).
    public func setClusters(_ clusters: [KubernetesCluster]) { self.clusters = clusters }

    /// Changes the simulated latency (tests use `.zero`).
    public func setLatency(_ latency: Duration) { self.latency = latency }

    public func clusterWorkloads(_ target: KubectlTarget) async throws -> ClusterWorkloads {
        let cluster = try cluster(for: target, action: .workloads)
        await pause()
        return state(of: cluster)
    }

    public func podEvents(_ target: KubectlTarget, namespace: String, pod: String) async throws -> [KubeEvent] {
        let cluster = try cluster(for: target, action: .podEvents(namespace: namespace, pod: pod))
        await pause()
        guard let found = state(of: cluster).pods.first(where: { $0.namespace == namespace && $0.name == pod })
        else { return [] }
        return MockWorkloads.events(for: found, in: cluster)
    }

    public nonisolated func podLogs(
        _ target: KubectlTarget, namespace: String, pod: String, options: PodLogOptions
    ) -> LineStream {
        let action = KubectlAction.logs(namespace: namespace, pod: pod, options: options)
        let command = action.displayCommand(in: target)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for line in try await self.logLines(target, action: action, command: command) {
                        continuation.yield(line)
                    }
                    // A followed log of a running pod keeps printing until the reader goes away.
                    while options.follow, !options.previous {
                        try await Task.sleep(for: .seconds(2))
                        guard try await self.isHealthy(target, namespace: namespace, pod: pod) else { break }
                        continuation.yield(OutputLine("GET /healthz 200"))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: BackendError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func logLines(_ target: KubectlTarget, action: KubectlAction, command: String) throws -> [OutputLine] {
        guard case .logs(let namespace, let name, let options) = action else { return [] }
        let cluster = try cluster(for: target, action: action)
        guard let pod = state(of: cluster).pods.first(where: { $0.namespace == namespace && $0.name == name }) else {
            throw MockWorkloads.notFound("pods", name, command: command)
        }
        return try MockWorkloads.logLines(for: pod, options: options, command: command)
    }

    private func isHealthy(_ target: KubectlTarget, namespace: String, pod: String) throws -> Bool {
        let cluster = try cluster(for: target, action: .workloads)
        return state(of: cluster).pods.first { $0.namespace == namespace && $0.name == pod }?.health == .healthy
    }

    public func deletePod(_ target: KubectlTarget, namespace: String, name: String) async throws {
        let action = KubectlAction.deletePod(namespace: namespace, name: name)
        var workloads = state(of: try cluster(for: target, action: action))
        await pause()
        try MockWorkloads.deletePod(
            &workloads, namespace: namespace, name: name, command: action.displayCommand(in: target))
        workloadStates[target.cluster] = workloads
    }

    public func restartDeployment(_ target: KubectlTarget, namespace: String, name: String) async throws {
        let action = KubectlAction.restartDeployment(namespace: namespace, name: name)
        var workloads = state(of: try cluster(for: target, action: action))
        await pause()
        try MockWorkloads.restart(
            &workloads, namespace: namespace, name: name, command: action.displayCommand(in: target))
        workloadStates[target.cluster] = workloads
    }

    public func scaleDeployment(
        _ target: KubectlTarget, namespace: String, name: String, replicas: Int
    ) async throws {
        guard replicas >= 0 else { throw BackendError.other("A deployment cannot have fewer than 0 replicas.") }
        let action = KubectlAction.scaleDeployment(namespace: namespace, name: name, replicas: replicas)
        var workloads = state(of: try cluster(for: target, action: action))
        await pause()
        try MockWorkloads.scale(
            &workloads, namespace: namespace, name: name, replicas: replicas,
            command: action.displayCommand(in: target))
        workloadStates[target.cluster] = workloads
    }
}
