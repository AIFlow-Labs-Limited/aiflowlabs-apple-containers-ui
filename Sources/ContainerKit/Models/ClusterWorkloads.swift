import Foundation

/// What runs in one cluster: the answer to a single
/// `kubectl get pods,deployments,services,nodes,namespaces --all-namespaces -o json`.
///
/// That command prints one `List` whose `items` mix the kinds. Decoding sorts them by `kind`; an item of a
/// kind this app does not show is ignored, and one that cannot be decoded is skipped and counted, so a single
/// odd object never empties the view.
public struct ClusterWorkloads: Hashable, Sendable {
    public var pods: [KubePod]
    public var deployments: [KubeDeployment]
    public var services: [KubeService]
    public var nodes: [KubeNode]
    public var namespaces: [KubeNamespace]
    /// Items of a known kind that could not be decoded.
    public var droppedCount: Int

    public init(
        pods: [KubePod] = [], deployments: [KubeDeployment] = [], services: [KubeService] = [],
        nodes: [KubeNode] = [], namespaces: [KubeNamespace] = [], droppedCount: Int = 0
    ) {
        self.pods = pods; self.deployments = deployments; self.services = services; self.nodes = nodes;
        self.namespaces = namespaces; self.droppedCount = droppedCount
    }

    /// The pods a deployment's selector matches.
    public func pods(of deployment: KubeDeployment) -> [KubePod] { pods.filter(deployment.selects) }
}

extension ClusterWorkloads: Decodable {
    private enum CodingKeys: String, CodingKey { case items }

    /// One element of `items`, decoded by its `kind`.
    private enum Item: Decodable {
        case pod(KubePod)
        case deployment(KubeDeployment)
        case service(KubeService)
        case node(KubeNode)
        case namespace(KubeNamespace)
        case other

        private enum Keys: String, CodingKey { case kind }

        init(from decoder: any Decoder) throws {
            switch try decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .kind) {
            case "Pod": self = .pod(try KubePod(from: decoder))
            case "Deployment": self = .deployment(try KubeDeployment(from: decoder))
            case "Service": self = .service(try KubeService(from: decoder))
            case "Node": self = .node(try KubeNode(from: decoder))
            case "Namespace": self = .namespace(try KubeNamespace(from: decoder))
            default: self = .other
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let items = try container.decodeIfPresent(LossyArray<Item>.self, forKey: .items) ?? LossyArray(elements: [])
        self.init(droppedCount: items.droppedCount)
        for item in items.elements {
            switch item {
            case .pod(let pod): pods.append(pod)
            case .deployment(let deployment): deployments.append(deployment)
            case .service(let service): services.append(service)
            case .node(let node): nodes.append(node)
            case .namespace(let namespace): namespaces.append(namespace)
            case .other: break
            }
        }
    }
}

/// `kubectl get <one kind> -o json`: a `List` of items of the same kind, decoded leniently.
public struct KubeList<Element: Decodable & Sendable>: Decodable, Sendable {
    public var items: [Element]

    private enum CodingKeys: String, CodingKey { case items }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent(LossyArray<Element>.self, forKey: .items)?.elements ?? []
    }
}
