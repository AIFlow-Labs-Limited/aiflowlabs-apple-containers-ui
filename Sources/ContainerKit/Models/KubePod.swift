import Foundation

// Kubernetes API objects as `kubectl get … -o json` prints them. Field names mirror the JSON; everything the
// API may leave out is optional, so a newer or older Kubernetes never fails a decode. Derived values live in
// `KubePod+Status.swift` and `KubeResources.swift`.

/// `metadata` of any Kubernetes object.
public struct KubeMetadata: Codable, Hashable, Sendable {
    public var name: String
    /// `nil` for cluster-scoped objects (nodes, namespaces).
    public var namespace: String?
    public var uid: String?
    public var creationTimestamp: Date?
    /// Set while the object is being deleted.
    public var deletionTimestamp: Date?
    public var labels: [String: String]?
    public var ownerReferences: [OwnerReference]?

    /// The object that owns this one (a ReplicaSet for a Deployment's pod).
    public struct OwnerReference: Codable, Hashable, Sendable {
        public var kind: String?
        public var name: String?
        public init(kind: String? = nil, name: String? = nil) { self.kind = kind; self.name = name }
    }

    public init(
        name: String, namespace: String? = nil, uid: String? = nil, creationTimestamp: Date? = nil,
        deletionTimestamp: Date? = nil, labels: [String: String]? = nil, ownerReferences: [OwnerReference]? = nil
    ) {
        self.name = name; self.namespace = namespace; self.uid = uid; self.creationTimestamp = creationTimestamp;
        self.deletionTimestamp = deletionTimestamp; self.labels = labels; self.ownerReferences = ownerReferences
    }
}

/// `status.phase` of a pod. A value this app does not know decodes to `.unknown`.
public enum KubePodPhase: String, Codable, Hashable, Sendable {
    case pending = "Pending"
    case running = "Running"
    case succeeded = "Succeeded"
    case failed = "Failed"
    case unknown = "Unknown"

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// A pod (`kind: Pod`).
public struct KubePod: Codable, Identifiable, Hashable, Sendable {
    public var metadata: KubeMetadata
    public var spec: Spec?
    public var status: Status?

    public struct Spec: Codable, Hashable, Sendable {
        public var nodeName: String?
        public var containers: [ContainerSpec]?
        public var initContainers: [ContainerSpec]?
        public init(nodeName: String? = nil, containers: [ContainerSpec]? = nil, initContainers: [ContainerSpec]? = nil)
        {
            self.nodeName = nodeName; self.containers = containers; self.initContainers = initContainers
        }
    }

    public struct ContainerSpec: Codable, Hashable, Sendable {
        public var name: String
        public var image: String?
        public init(name: String, image: String? = nil) { self.name = name; self.image = image }
    }

    public struct Status: Codable, Hashable, Sendable {
        public var phase: KubePodPhase?
        /// Why the pod as a whole is in its phase (`Evicted`, `NodeLost`); usually absent.
        public var reason: String?
        public var message: String?
        public var podIP: String?
        public var hostIP: String?
        public var startTime: Date?
        public var conditions: [Condition]?
        public var containerStatuses: [ContainerStatus]?
        public var initContainerStatuses: [ContainerStatus]?

        public init(
            phase: KubePodPhase? = nil, reason: String? = nil, message: String? = nil, podIP: String? = nil,
            hostIP: String? = nil, startTime: Date? = nil, conditions: [Condition]? = nil,
            containerStatuses: [ContainerStatus]? = nil, initContainerStatuses: [ContainerStatus]? = nil
        ) {
            self.phase = phase; self.reason = reason; self.message = message; self.podIP = podIP;
            self.hostIP = hostIP; self.startTime = startTime; self.conditions = conditions;
            self.containerStatuses = containerStatuses; self.initContainerStatuses = initContainerStatuses
        }
    }

    /// A pod or node condition (`type: Ready`, `status: "True"`).
    public struct Condition: Codable, Hashable, Sendable {
        public var type: String?
        /// `"True"`, `"False"` or `"Unknown"`, as a string.
        public var status: String?
        public var reason: String?
        public var message: String?
        public init(type: String? = nil, status: String? = nil, reason: String? = nil, message: String? = nil) {
            self.type = type; self.status = status; self.reason = reason; self.message = message
        }
    }

    public struct ContainerStatus: Codable, Hashable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        public var image: String?
        public var ready: Bool?
        public var restartCount: Int?
        public var started: Bool?
        public var state: StateDetail?
        /// The previous instance, when the container was restarted (an empty object otherwise).
        public var lastState: StateDetail?

        public init(
            name: String, image: String? = nil, ready: Bool? = nil, restartCount: Int? = nil, started: Bool? = nil,
            state: StateDetail? = nil, lastState: StateDetail? = nil
        ) {
            self.name = name; self.image = image; self.ready = ready; self.restartCount = restartCount;
            self.started = started; self.state = state; self.lastState = lastState
        }
    }

    /// Exactly one of the three is set for a current state; none for an empty `lastState`.
    public struct StateDetail: Codable, Hashable, Sendable {
        public var waiting: Waiting?
        public var running: Running?
        public var terminated: Terminated?

        public struct Waiting: Codable, Hashable, Sendable {
            public var reason: String?
            public var message: String?
            public init(reason: String? = nil, message: String? = nil) { self.reason = reason; self.message = message }
        }

        public struct Running: Codable, Hashable, Sendable {
            public var startedAt: Date?
            public init(startedAt: Date? = nil) { self.startedAt = startedAt }
        }

        public struct Terminated: Codable, Hashable, Sendable {
            public var reason: String?
            public var message: String?
            public var exitCode: Int?
            public var signal: Int?
            public var startedAt: Date?
            public var finishedAt: Date?
            public init(
                reason: String? = nil, message: String? = nil, exitCode: Int? = nil, signal: Int? = nil,
                startedAt: Date? = nil, finishedAt: Date? = nil
            ) {
                self.reason = reason; self.message = message; self.exitCode = exitCode; self.signal = signal;
                self.startedAt = startedAt; self.finishedAt = finishedAt
            }
        }

        public init(waiting: Waiting? = nil, running: Running? = nil, terminated: Terminated? = nil) {
            self.waiting = waiting; self.running = running; self.terminated = terminated
        }
    }

    public init(metadata: KubeMetadata, spec: Spec? = nil, status: Status? = nil) {
        self.metadata = metadata; self.spec = spec; self.status = status
    }

    /// `namespace/name`: unique in a cluster, and stable while the pod exists.
    public var id: String { "\(namespace)/\(name)" }
    public var name: String { metadata.name }
    public var namespace: String { metadata.namespace ?? "default" }
}
