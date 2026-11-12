import Foundation

/// Aggregate state of a cluster as `container cluster list --format json` reports it (`status.state`).
/// `running`: every node is up; `degraded`: some are; `stopped`: none is. Unknown strings decode to `.unknown`.
public enum KubernetesClusterState: String, Codable, Hashable, Sendable, CaseIterable {
    case running, degraded, stopped, unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = KubernetesClusterState(rawValue: raw) ?? .unknown
    }
}

/// One element of `container cluster list --format json` (container 1.7 and later). Field names mirror Apple's
/// `ClusterResource` / `ClusterConfiguration` / `ClusterStatus`; only the names are required, every other key
/// may be missing or `null`.
public struct ClusterResource: Codable, Identifiable, Hashable, Sendable {
    /// Same as `configuration.name`.
    public var id: String
    /// What the cluster was created with.
    public var configuration: Configuration
    /// Aggregate and per-node runtime state.
    public var status: Status

    /// The settings recorded by `container cluster create`.
    public struct Configuration: Codable, Hashable, Sendable {
        public var name: String
        /// The node image's tag, e.g. `v1.35.5`.
        public var kubernetesVersion: String?
        /// `--cni` as given (`null` for the bundled kindnet, `NONE` for no CNI, else a manifest path).
        public var cni: String?
        /// DNS name of the API server (`<name>.<dns.domain>`), `null` when no DNS domain is configured.
        public var fqdn: String?
        /// `--rm`: node containers are removed when they stop.
        public var remove: Bool
        /// `--shared-image-store`: nodes can use the local image store.
        public var sharedImageStore: Bool
        /// The control-plane node first, then workers named `<cluster>-worker-<n>`.
        public var nodes: [NodeConfiguration]
        public var creationDate: Date?
        public var labels: [String: String]

        public init(
            name: String, kubernetesVersion: String? = nil, cni: String? = nil, fqdn: String? = nil,
            remove: Bool = false, sharedImageStore: Bool = false, nodes: [NodeConfiguration] = [],
            creationDate: Date? = nil, labels: [String: String] = [:]
        ) {
            self.name = name; self.kubernetesVersion = kubernetesVersion; self.cni = cni; self.fqdn = fqdn
            self.remove = remove; self.sharedImageStore = sharedImageStore; self.nodes = nodes
            self.creationDate = creationDate; self.labels = labels
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            kubernetesVersion = try? c.decodeIfPresent(String.self, forKey: .kubernetesVersion)
            cni = try? c.decodeIfPresent(String.self, forKey: .cni)
            fqdn = try? c.decodeIfPresent(String.self, forKey: .fqdn)
            remove = (try? c.decodeIfPresent(Bool.self, forKey: .remove)) ?? false
            sharedImageStore = (try? c.decodeIfPresent(Bool.self, forKey: .sharedImageStore)) ?? false
            nodes = (try? c.decodeIfPresent(LossyArray<NodeConfiguration>.self, forKey: .nodes))?.elements ?? []
            creationDate = try? c.decodeIfPresent(Date.self, forKey: .creationDate)
            labels = (try? c.decodeIfPresent([String: String].self, forKey: .labels)) ?? [:]
        }
    }

    /// A node as configured: its container name and Kubernetes roles.
    public struct NodeConfiguration: Codable, Hashable, Sendable {
        public var name: String
        /// `linux` today.
        public var kind: String?
        /// `control-plane`, `worker`, or both for a single-node cluster.
        public var roles: [String]

        public init(name: String, kind: String? = "linux", roles: [String]) {
            self.name = name; self.kind = kind; self.roles = roles
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            kind = try? c.decodeIfPresent(String.self, forKey: .kind)
            roles = (try? c.decodeIfPresent([String].self, forKey: .roles)) ?? []
        }
    }

    /// `status`: the aggregate state and one entry per configured node.
    public struct Status: Codable, Hashable, Sendable {
        public var state: KubernetesClusterState
        public var nodes: [NodeState]

        public init(state: KubernetesClusterState, nodes: [NodeState] = []) {
            self.state = state; self.nodes = nodes
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = (try? c.decodeIfPresent(KubernetesClusterState.self, forKey: .state)) ?? .unknown
            nodes = (try? c.decodeIfPresent(LossyArray<NodeState>.self, forKey: .nodes))?.elements ?? []
        }
    }

    /// A node's container state. `addresses` and `ports` are left out of the JSON when the container has none.
    public struct NodeState: Codable, Hashable, Sendable {
        public var name: String
        /// The node container's runtime status (`running`, `stopped`, `stopping`, `unknown`).
        public var status: ContainerState
        /// IPv4 addresses without a prefix length, e.g. `192.168.64.5`.
        public var addresses: [String]?
        /// Published ports as `host->container`, e.g. `6443->6443`.
        public var ports: [String]?

        public init(name: String, status: ContainerState, addresses: [String]? = nil, ports: [String]? = nil) {
            self.name = name; self.status = status; self.addresses = addresses; self.ports = ports
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            status = (try? c.decodeIfPresent(ContainerState.self, forKey: .status)) ?? .unknown
            addresses = try? c.decodeIfPresent([String].self, forKey: .addresses)
            ports = try? c.decodeIfPresent([String].self, forKey: .ports)
        }
    }

    public init(configuration: Configuration, status: Status) {
        id = configuration.name
        self.configuration = configuration
        self.status = status
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try c.decode(Configuration.self, forKey: .configuration)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? configuration.name
        status = (try? c.decodeIfPresent(Status.self, forKey: .status)) ?? Status(state: .unknown)
    }

    /// Same as `configuration.name`.
    public var name: String { configuration.name }
}

// MARK: - Folding into KubernetesCluster

extension KubernetesCluster {
    /// Builds the app's cluster model from a JSON `ClusterResource`.
    ///
    /// The JSON has no CPU or memory figures, so they are taken from `nodeTable`: the clusters parsed from
    /// `container cluster list --nodes` (matched by cluster and node name; missing rows leave both at 0).
    public init(resource: ClusterResource, nodeTable: [KubernetesCluster] = []) {
        let sized = nodeTable.first { $0.name == resource.name }?.nodes ?? []
        var nodes: [Node] = []
        var seen: Set<String> = []
        func node(_ name: String, roles: [String], state: ClusterResource.NodeState?) -> Node {
            let row = sized.first { $0.name == name }
            let joined = { (values: [String]?) -> String? in
                guard let values, !values.isEmpty else { return nil }
                return values.joined(separator: ",")
            }
            return Node(
                name: name,
                role: roles.isEmpty ? (row?.role ?? "") : roles.joined(separator: ","),
                // Apple reports a node whose container is gone as stopped; do the same when the entry is missing.
                state: state?.status ?? row?.state ?? .stopped,
                cpus: row?.cpus ?? 0, memoryMB: row?.memoryMB ?? 0,
                address: joined(state?.addresses) ?? row?.address, ports: joined(state?.ports) ?? row?.ports)
        }
        for configured in resource.configuration.nodes where seen.insert(configured.name).inserted {
            let state = resource.status.nodes.first { $0.name == configured.name }
            nodes.append(node(configured.name, roles: configured.roles, state: state))
        }
        // Be lenient about a status entry without a configuration entry: show it rather than drop it.
        for state in resource.status.nodes where seen.insert(state.name).inserted {
            nodes.append(node(state.name, roles: [], state: state))
        }
        self.init(name: resource.name, nodes: nodes)
        kubernetesVersion = resource.configuration.kubernetesVersion
        reportedState = resource.status.state == .unknown ? nil : resource.status.state
        sharedImageStore = resource.configuration.sharedImageStore
        cni = resource.configuration.cni
        fqdn = resource.configuration.fqdn
        removeOnStop = resource.configuration.remove
        creationDate = resource.configuration.creationDate
    }
}
