import Foundation

// Cluster nodes are containers. Up to container 1.6 they show up in `container list` and can be started,
// stopped and deleted like any other container. From 1.7 the CLI hides them from `container list` (even with
// `--all`) and reports them as "not found" to start / stop / kill / delete, while inspect, logs, exec and stats
// keep working. The app's Containers list, "in use" checks and memory totals are built on the container list,
// so this file makes both behaviours look the same to the rest of the app:
//
//  * `addingHiddenClusterNodes` appends the node containers the listing left out (read with `container inspect`);
//  * `executeLifecycle` turns the CLI's "not found" for a known node into an explanation.
//
// Which behaviour the CLI has is observed, not looked up: as soon as a known node appears in `container list`
// the CLI evidently lists nodes itself and nothing is appended.

/// What the last `listClusters()` said about node containers.
struct ClusterNodeIndex: Sendable {
    /// Every node container name, mapped to its cluster.
    var clusterByNode: [String: String] = [:]
    /// Nodes whose container was reported running or stopping, i.e. certain to exist.
    var liveNodes: [String] = []
    /// Set once a known node was seen in `container list`: this CLI does not hide nodes.
    var listedByCLI = false
}

extension Container {
    /// Whether this container is a node of a local Kubernetes cluster (created by the `k8s` / `cluster` plugin).
    /// The CLI manages such containers itself; from container 1.7 it refuses to start, stop or delete them.
    public var isClusterNode: Bool {
        guard let plugin = labels[ResourceLabel.plugin] else { return false }
        return KubernetesCapabilities.commandWords.contains(plugin)
    }
}

extension CLIBackend {
    /// Records the node containers of `clusters` (from the latest `listClusters()`).
    func rememberClusterNodes(_ clusters: [KubernetesCluster]) {
        var index = ClusterNodeIndex()
        index.listedByCLI = clusterNodes.listedByCLI
        for cluster in clusters {
            for node in cluster.nodes {
                index.clusterByNode[node.name] = cluster.name
                if node.state == .running || node.state == .stopping { index.liveNodes.append(node.name) }
            }
        }
        clusterNodes = index
    }

    /// Appends the live cluster node containers that `container list` did not return, so the app sees them the
    /// way older CLIs list them. Best effort: when `container inspect` fails (a node went away since the last
    /// cluster listing) the plain listing is returned and the stale names are forgotten until clusters are
    /// listed again.
    func addingHiddenClusterNodes(to listed: [Container], includeStopped: Bool) async -> [Container] {
        guard !clusterNodes.listedByCLI, !clusterNodes.liveNodes.isEmpty else { return listed }
        let present = Set(listed.map(\.id))
        // A node known to be running is in the listing: this CLI lists nodes itself (1.6 and earlier).
        if clusterNodes.liveNodes.contains(where: present.contains) {
            clusterNodes.listedByCLI = true
            return listed
        }
        let hidden = clusterNodes.liveNodes
        do {
            let nodes = try await decodeList(Container.self, ["inspect", "--"] + hidden)
            return listed + nodes.filter { !present.contains($0.id) && (includeStopped || $0.isRunning) }
        } catch {
            clusterNodes.liveNodes = []
            return listed
        }
    }

    /// Runs a start / stop / kill / delete command for one container. When the CLI answers "not found" for a
    /// container known to be a cluster node, the error says why instead (container 1.7+ protects nodes).
    func executeLifecycle(_ arguments: [String], id: String, action: String, timeout: Duration) async throws {
        do {
            try await execute(arguments, timeout: timeout)
        } catch let error as BackendError {
            throw clusterNodeError(error, id: id, action: action)
        }
    }

    /// `error`, or the explanation for a refused cluster node (`action` reads like "Stopping").
    func clusterNodeError(_ error: BackendError, id: String, action: String) -> BackendError {
        guard let cluster = clusterNodes.clusterByNode[id], Self.isNotFound(error) else { return error }
        return .unsupported(
            feature: "\(action) the cluster node “\(id)”",
            reason: "it belongs to the Kubernetes cluster “\(cluster)”, and this container CLI only changes "
                + "cluster nodes through the cluster. Delete the cluster in the Kubernetes section instead.")
    }

    private static func isNotFound(_ error: BackendError) -> Bool {
        switch error {
        case .notFound: return true
        case .commandFailed(_, _, let message): return message.localizedCaseInsensitiveContains("not found")
        default: return false
        }
    }
}
