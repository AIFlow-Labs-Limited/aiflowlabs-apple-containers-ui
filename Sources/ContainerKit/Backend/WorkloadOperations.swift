import Foundation

/// What runs inside a local cluster: pods, deployments, services, and the few things a developer does to them.
///
/// Implementations reach the API server with the `kubectl` inside the cluster's control-plane node (see
/// `Kubectl.swift`), so none of this needs `kubectl`, a kubeconfig or a DNS domain on the Mac. Every call
/// takes the `KubectlTarget` of a running cluster (`KubernetesCluster.kubectlTarget`).
public protocol KubernetesWorkloadOperations: Sendable {
    /// Pods, deployments, services, nodes and namespaces of the whole cluster, in one call.
    func clusterWorkloads(_ target: KubectlTarget) async throws -> ClusterWorkloads
    /// Events about one pod, oldest first.
    func podEvents(_ target: KubectlTarget, namespace: String, pod: String) async throws -> [KubeEvent]
    /// `kubectl logs`. With `options.follow` the stream stays open until it is cancelled.
    func podLogs(_ target: KubectlTarget, namespace: String, pod: String, options: PodLogOptions) -> LineStream
    /// `kubectl delete pod`. A pod owned by a Deployment is replaced by a new one.
    func deletePod(_ target: KubectlTarget, namespace: String, name: String) async throws
    /// `kubectl rollout restart`: replaces the deployment's pods one by one.
    func restartDeployment(_ target: KubectlTarget, namespace: String, name: String) async throws
    /// `kubectl scale --replicas`.
    func scaleDeployment(_ target: KubectlTarget, namespace: String, name: String, replicas: Int) async throws
}
