import Foundation

/// A Deployment (`kind: Deployment`, `apps/v1`).
public struct KubeDeployment: Codable, Identifiable, Hashable, Sendable {
    public var metadata: KubeMetadata
    public var spec: Spec?
    public var status: Status?

    public struct Spec: Codable, Hashable, Sendable {
        /// Desired pod count.
        public var replicas: Int?
        public var selector: Selector?
        public init(replicas: Int? = nil, selector: Selector? = nil) {
            self.replicas = replicas; self.selector = selector
        }
    }

    public struct Selector: Codable, Hashable, Sendable {
        public var matchLabels: [String: String]?
        public init(matchLabels: [String: String]? = nil) { self.matchLabels = matchLabels }
    }

    /// Counts the API leaves out when they are zero.
    public struct Status: Codable, Hashable, Sendable {
        public var replicas: Int?
        public var readyReplicas: Int?
        public var updatedReplicas: Int?
        public var availableReplicas: Int?
        public var unavailableReplicas: Int?
        public init(
            replicas: Int? = nil, readyReplicas: Int? = nil, updatedReplicas: Int? = nil,
            availableReplicas: Int? = nil, unavailableReplicas: Int? = nil
        ) {
            self.replicas = replicas; self.readyReplicas = readyReplicas; self.updatedReplicas = updatedReplicas;
            self.availableReplicas = availableReplicas; self.unavailableReplicas = unavailableReplicas
        }
    }

    public init(metadata: KubeMetadata, spec: Spec? = nil, status: Status? = nil) {
        self.metadata = metadata; self.spec = spec; self.status = status
    }

    public var id: String { "\(namespace)/\(name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var desiredReplicas: Int { spec?.replicas ?? 0 }
    public var readyReplicas: Int { status?.readyReplicas ?? 0 }
    public var updatedReplicas: Int { status?.updatedReplicas ?? 0 }
    public var availableReplicas: Int { status?.availableReplicas ?? 0 }
    /// `2/3`, as in the READY column.
    public var readyText: String { "\(readyReplicas)/\(desiredReplicas)" }
    /// Every desired pod is ready and on the current revision.
    public var isSettled: Bool {
        readyReplicas == desiredReplicas && updatedReplicas == desiredReplicas
            && (status?.replicas ?? 0) == desiredReplicas
    }

    /// Whether `pod` carries every label of this deployment's selector (and lives in its namespace).
    public func selects(_ pod: KubePod) -> Bool {
        guard let wanted = spec?.selector?.matchLabels, !wanted.isEmpty, pod.namespace == namespace else {
            return false
        }
        let labels = pod.metadata.labels ?? [:]
        return wanted.allSatisfy { labels[$0.key] == $0.value }
    }
}

/// A Service (`kind: Service`).
public struct KubeService: Codable, Identifiable, Hashable, Sendable {
    public var metadata: KubeMetadata
    public var spec: Spec?

    public struct Spec: Codable, Hashable, Sendable {
        /// `ClusterIP`, `NodePort`, `LoadBalancer` or `ExternalName`.
        public var type: String?
        public var clusterIP: String?
        public var externalIPs: [String]?
        public var externalName: String?
        public var ports: [Port]?
        public var selector: [String: String]?
        public init(
            type: String? = nil, clusterIP: String? = nil, externalIPs: [String]? = nil, externalName: String? = nil,
            ports: [Port]? = nil, selector: [String: String]? = nil
        ) {
            self.type = type; self.clusterIP = clusterIP; self.externalIPs = externalIPs;
            self.externalName = externalName; self.ports = ports; self.selector = selector
        }
    }

    public struct Port: Codable, Hashable, Sendable {
        public var name: String?
        public var port: Int
        public var nodePort: Int?
        public var `protocol`: String?
        public init(name: String? = nil, port: Int, nodePort: Int? = nil, protocol: String? = nil) {
            self.name = name; self.port = port; self.nodePort = nodePort; self.protocol = `protocol`
        }
    }

    public init(metadata: KubeMetadata, spec: Spec? = nil) { self.metadata = metadata; self.spec = spec }

    public var id: String { "\(namespace)/\(name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
    public var type: String { spec?.type ?? "ClusterIP" }
    /// `80:30080/TCP,443/TCP`, as in the PORT(S) column.
    public var portsText: String {
        (spec?.ports ?? []).map { port in
            let number = port.nodePort.map { "\(port.port):\($0)" } ?? "\(port.port)"
            return "\(number)/\(port.protocol ?? "TCP")"
        }
        .joined(separator: ",")
    }
    /// External addresses (`externalIPs`, or the name of an `ExternalName` service).
    public var externalText: String? {
        if let ips = spec?.externalIPs, !ips.isEmpty { return ips.joined(separator: ",") }
        return spec?.externalName
    }
}

/// A node as Kubernetes sees it (`kind: Node`). The node's container is `KubernetesCluster.Node`.
public struct KubeNode: Codable, Identifiable, Hashable, Sendable {
    public var metadata: KubeMetadata
    public var spec: Spec?
    public var status: Status?

    public struct Spec: Codable, Hashable, Sendable {
        /// `true` after `kubectl cordon`.
        public var unschedulable: Bool?
        public init(unschedulable: Bool? = nil) { self.unschedulable = unschedulable }
    }

    public struct Status: Codable, Hashable, Sendable {
        public var conditions: [KubePod.Condition]?
        public var addresses: [Address]?
        public var nodeInfo: NodeInfo?
        public init(conditions: [KubePod.Condition]? = nil, addresses: [Address]? = nil, nodeInfo: NodeInfo? = nil) {
            self.conditions = conditions; self.addresses = addresses; self.nodeInfo = nodeInfo
        }
    }

    public struct Address: Codable, Hashable, Sendable {
        /// `InternalIP`, `Hostname`, …
        public var type: String?
        public var address: String?
        public init(type: String? = nil, address: String? = nil) { self.type = type; self.address = address }
    }

    public struct NodeInfo: Codable, Hashable, Sendable {
        public var kubeletVersion: String?
        public var osImage: String?
        public var containerRuntimeVersion: String?
        public var architecture: String?
        public init(
            kubeletVersion: String? = nil, osImage: String? = nil, containerRuntimeVersion: String? = nil,
            architecture: String? = nil
        ) {
            self.kubeletVersion = kubeletVersion; self.osImage = osImage;
            self.containerRuntimeVersion = containerRuntimeVersion; self.architecture = architecture
        }
    }

    public init(metadata: KubeMetadata, spec: Spec? = nil, status: Status? = nil) {
        self.metadata = metadata; self.spec = spec; self.status = status
    }

    static let roleLabelPrefix = "node-role.kubernetes.io/"

    public var id: String { metadata.name }
    public var name: String { metadata.name }
    /// The kubelet reports the node ready.
    public var isReady: Bool { status?.conditions?.contains { $0.type == "Ready" && $0.status == "True" } ?? false }
    /// `Ready`, `NotReady`, with `,SchedulingDisabled` for a cordoned node.
    public var statusText: String {
        (isReady ? "Ready" : "NotReady") + (spec?.unschedulable == true ? ",SchedulingDisabled" : "")
    }
    /// Roles from the `node-role.kubernetes.io/<role>` labels (`control-plane`); empty for a plain worker.
    public var roles: [String] {
        (metadata.labels ?? [:]).keys.filter { $0.hasPrefix(Self.roleLabelPrefix) }
            .map { String($0.dropFirst(Self.roleLabelPrefix.count)) }.sorted()
    }
    public var internalIP: String? { status?.addresses?.first { $0.type == "InternalIP" }?.address }
}

/// A namespace (`kind: Namespace`).
public struct KubeNamespace: Codable, Identifiable, Hashable, Sendable {
    public var metadata: KubeMetadata

    public init(metadata: KubeMetadata) { self.metadata = metadata }

    /// Namespaces Kubernetes and the node image create for themselves.
    public static let systemNames: Set<String> = [
        "kube-system", "kube-public", "kube-node-lease", "local-path-storage",
    ]

    public var id: String { metadata.name }
    public var name: String { metadata.name }
    /// Whether the namespace belongs to the cluster itself rather than to the user's workloads.
    public var isSystem: Bool { Self.isSystem(metadata.name) }
    public static func isSystem(_ name: String) -> Bool { systemNames.contains(name) }
}

/// An event (`kind: Event`): what happened to an object, as the scheduler and kubelet report it.
public struct KubeEvent: Codable, Identifiable, Hashable, Sendable {
    public var metadata: KubeMetadata
    /// `Normal` or `Warning`.
    public var type: String?
    public var reason: String?
    public var message: String?
    public var count: Int?
    public var firstTimestamp: Date?
    public var lastTimestamp: Date?
    /// Set instead of the two timestamps by components that use the newer events API.
    public var eventTime: Date?
    public var source: Source?

    public struct Source: Codable, Hashable, Sendable {
        public var component: String?
        public var host: String?
        public init(component: String? = nil, host: String? = nil) { self.component = component; self.host = host }
    }

    public init(
        metadata: KubeMetadata, type: String? = nil, reason: String? = nil, message: String? = nil, count: Int? = nil,
        firstTimestamp: Date? = nil, lastTimestamp: Date? = nil, eventTime: Date? = nil, source: Source? = nil
    ) {
        self.metadata = metadata; self.type = type; self.reason = reason; self.message = message;
        self.count = count; self.firstTimestamp = firstTimestamp; self.lastTimestamp = lastTimestamp;
        self.eventTime = eventTime; self.source = source
    }

    public var id: String { metadata.uid ?? metadata.name }
    public var isWarning: Bool { type == "Warning" }
    /// When the event last happened.
    public var lastSeen: Date? { lastTimestamp ?? eventTime ?? firstTimestamp ?? metadata.creationTimestamp }
}
