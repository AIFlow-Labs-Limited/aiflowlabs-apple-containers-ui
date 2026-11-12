import Foundation

/// A local cluster (`container k8s`, later `container cluster`). Nodes are containers. CLIs up to 1.6 print a
/// per-node table only, so the optional fields below stay `nil`; 1.7 and later report them as JSON
/// (`ClusterResource`, folded in by `KubernetesCluster.init(resource:nodeTable:)`).
public struct KubernetesCluster: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var nodes: [Node]
    /// The node image's tag (`v1.35.5`); `nil` when the CLI does not report it.
    public var kubernetesVersion: String?
    /// `status.state` as reported by the CLI; `nil` for table-only CLIs (use `state`, which derives it).
    public var reportedState: KubernetesClusterState?
    /// Whether nodes can use the local image store; `nil` when the CLI has no such feature.
    public var sharedImageStore: Bool?
    /// `--cni` as given: `nil` for the bundled kindnet (or unknown), `NONE`, or a manifest path.
    public var cni: String?
    /// DNS name of the API server, when the CLI reports one.
    public var fqdn: String?
    /// Whether the cluster was created with `--rm`; `nil` when unknown.
    public var removeOnStop: Bool?
    public var creationDate: Date?

    public struct Node: Codable, Identifiable, Hashable, Sendable {
        public var id: String { name }
        public var name: String
        public var role: String
        public var state: ContainerState
        public var cpus: Int
        public var memoryMB: Int64
        public var address: String?
        public var ports: String?
        public init(
            name: String, role: String, state: ContainerState, cpus: Int, memoryMB: Int64, address: String? = nil,
            ports: String? = nil
        ) {
            self.name = name; self.role = role; self.state = state; self.cpus = cpus; self.memoryMB = memoryMB;
            self.address = address; self.ports = ports
        }
    }

    public init(name: String, nodes: [Node]) { self.name = name; self.nodes = nodes }
    public var isRunning: Bool { nodes.contains { $0.state == .running } }
}

extension KubernetesCluster {
    /// The cluster's state: what the CLI reported, else derived from the nodes the same way the CLI does
    /// (all up: running, some up: degraded, none up: stopped; no nodes: unknown).
    public var state: KubernetesClusterState {
        if let reportedState { return reportedState }
        guard !nodes.isEmpty else { return .unknown }
        let up = runningNodeCount
        return up == 0 ? .stopped : (up == nodes.count ? .running : .degraded)
    }

    /// Nodes whose container is running.
    public var runningNodeCount: Int { nodes.count { $0.state == .running } }

    /// `running`, `stopped`, `unknown`, or `degraded (2 of 3 up)`: the wording of `container cluster list`.
    public var stateDescription: String {
        switch state {
        case .degraded: return "degraded (\(runningNodeCount) of \(nodes.count) up)"
        case .running, .stopped, .unknown: return state.rawValue
        }
    }

    /// The node that carries the `control-plane` role (the first node when none says so).
    public var controlPlaneNode: Node? { nodes.first { $0.isControlPlane } ?? nodes.first }

    /// Dedicated worker nodes (a single-node cluster has none: its only node is also the control plane).
    public var workerNodes: [Node] { nodes.filter { !$0.isControlPlane } }
}

extension KubernetesCluster.Node {
    /// Whether the node's roles include `control-plane`.
    public var isControlPlane: Bool { role.localizedCaseInsensitiveContains("control-plane") }
}
