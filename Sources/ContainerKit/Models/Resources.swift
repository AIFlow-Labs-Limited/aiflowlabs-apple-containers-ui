import Foundation

// MARK: - Volumes

/// `container volume ls --format json` element.
public struct Volume: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var configuration: Configuration

    public struct Configuration: Codable, Hashable, Sendable {
        public var name: String
        public var driver: String
        public var format: String
        public var creationDate: Date
        public var labels: [String: String]
        public var options: [String: String]
        /// Maximum size of the sparse image (not current usage).
        public var sizeInBytes: Int64
        /// Backing `volume.img` path on the host.
        public var source: String

        public init(
            name: String, driver: String = "local", format: String = "ext4", creationDate: Date,
            labels: [String: String] = [:], options: [String: String] = [:], sizeInBytes: Int64, source: String
        ) {
            self.name = name; self.driver = driver; self.format = format; self.creationDate = creationDate
            self.labels = labels; self.options = options; self.sizeInBytes = sizeInBytes; self.source = source
        }

        /// Only `name` is required; secondary fields fall back to defaults, an unreadable date to the epoch.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            driver = try c.decodeIfPresent(String.self, forKey: .driver) ?? "local"
            format = try c.decodeIfPresent(String.self, forKey: .format) ?? "ext4"
            creationDate = LenientDecoding.date(c, .creationDate)
            labels = (try? c.decodeIfPresent([String: String].self, forKey: .labels)) ?? [:]
            options = (try? c.decodeIfPresent([String: String].self, forKey: .options)) ?? [:]
            sizeInBytes = (try? c.decodeIfPresent(Int64.self, forKey: .sizeInBytes)) ?? 0
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        }
    }

    public init(id: String, configuration: Configuration) { self.id = id; self.configuration = configuration }

    public var name: String { configuration.name }
    public var isAnonymous: Bool { configuration.labels[ResourceLabel.anonymousVolume] != nil }
}

// MARK: - Networks

/// `container network ls --format json` element.
public struct Network: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var configuration: Configuration
    public var status: Status?

    public struct Configuration: Codable, Hashable, Sendable {
        public var name: String
        public var mode: String
        public var plugin: String?
        public var creationDate: Date
        public var labels: [String: String]
        public var options: [String: String]

        public init(
            name: String, mode: String = "nat", plugin: String? = "container-network-vmnet", creationDate: Date,
            labels: [String: String] = [:], options: [String: String] = [:]
        ) {
            self.name = name; self.mode = mode; self.plugin = plugin; self.creationDate = creationDate
            self.labels = labels; self.options = options
        }

        /// Only `name` is required; secondary fields fall back to defaults, an unreadable date to the epoch.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "nat"
            plugin = try c.decodeIfPresent(String.self, forKey: .plugin)
            creationDate = LenientDecoding.date(c, .creationDate)
            labels = (try? c.decodeIfPresent([String: String].self, forKey: .labels)) ?? [:]
            options = (try? c.decodeIfPresent([String: String].self, forKey: .options)) ?? [:]
        }
    }

    public struct Status: Codable, Hashable, Sendable {
        public var ipv4Gateway: String?
        public var ipv4Subnet: String?
        public var ipv6Subnet: String?
        public init(ipv4Gateway: String?, ipv4Subnet: String?, ipv6Subnet: String? = nil) {
            self.ipv4Gateway = ipv4Gateway; self.ipv4Subnet = ipv4Subnet; self.ipv6Subnet = ipv6Subnet
        }
    }

    public init(id: String, configuration: Configuration, status: Status? = nil) {
        self.id = id; self.configuration = configuration; self.status = status
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        configuration = try c.decode(Configuration.self, forKey: .configuration)
        status = try? c.decodeIfPresent(Status.self, forKey: .status)
    }

    public var name: String { configuration.name }
    public var isBuiltin: Bool { configuration.labels[ResourceLabel.role] == ResourceLabel.Role.builtin }
}

// MARK: - Stats

/// `container stats --no-stream --format json` element. CPU is cumulative µs; compute % from two samples.
public struct ContainerStats: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var cpuUsageUsec: Int64
    public var memoryUsageBytes: Int64
    public var memoryLimitBytes: Int64
    public var networkRxBytes: Int64
    public var networkTxBytes: Int64
    public var blockReadBytes: Int64
    public var blockWriteBytes: Int64
    public var numProcesses: Int

    public init(
        id: String, cpuUsageUsec: Int64, memoryUsageBytes: Int64, memoryLimitBytes: Int64,
        networkRxBytes: Int64 = 0, networkTxBytes: Int64 = 0, blockReadBytes: Int64 = 0,
        blockWriteBytes: Int64 = 0, numProcesses: Int = 1
    ) {
        self.id = id; self.cpuUsageUsec = cpuUsageUsec; self.memoryUsageBytes = memoryUsageBytes
        self.memoryLimitBytes = memoryLimitBytes; self.networkRxBytes = networkRxBytes;
        self.networkTxBytes = networkTxBytes
        self.blockReadBytes = blockReadBytes; self.blockWriteBytes = blockWriteBytes; self.numProcesses = numProcesses
    }

    /// Only `id` is required; missing counters read as 0.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func int64(_ key: CodingKeys) -> Int64 { (try? c.decodeIfPresent(Int64.self, forKey: key)) ?? 0 }
        id = try c.decode(String.self, forKey: .id)
        cpuUsageUsec = int64(.cpuUsageUsec)
        memoryUsageBytes = int64(.memoryUsageBytes)
        memoryLimitBytes = int64(.memoryLimitBytes)
        networkRxBytes = int64(.networkRxBytes)
        networkTxBytes = int64(.networkTxBytes)
        blockReadBytes = int64(.blockReadBytes)
        blockWriteBytes = int64(.blockWriteBytes)
        numProcesses = (try? c.decodeIfPresent(Int.self, forKey: .numProcesses)) ?? 0
    }

    public var memoryFraction: Double { memoryLimitBytes > 0 ? Double(memoryUsageBytes) / Double(memoryLimitBytes) : 0 }

    /// CPU percent between two samples (100 = one full core).
    public static func cpuPercent(previous: ContainerStats, current: ContainerStats, interval: TimeInterval) -> Double {
        guard interval > 0 else { return 0 }
        let delta = Double(current.cpuUsageUsec - previous.cpuUsageUsec) / 1_000_000
        return max(0, delta / interval * 100)
    }
}

// MARK: - System

/// `container system status --format json`.
public struct SystemStatus: Codable, Hashable, Sendable {
    public var status: String
    public var client: Component?
    public var server: Component?
    public var host: Host?
    public var paths: Paths?
    public var resources: ResourceCounts?

    public struct Component: Codable, Hashable, Sendable {
        public var appName: String?
        public var version: String
        public var build: String?
        public var commit: String?
        public init(appName: String? = nil, version: String, build: String? = nil, commit: String? = nil) {
            self.appName = appName; self.version = version; self.build = build; self.commit = commit
        }
    }
    public struct Host: Codable, Hashable, Sendable {
        public var architecture: String
        public var cpus: Int
        public var operatingSystem: String
        public init(architecture: String, cpus: Int, operatingSystem: String) {
            self.architecture = architecture; self.cpus = cpus; self.operatingSystem = operatingSystem
        }
    }
    public struct Paths: Codable, Hashable, Sendable {
        public var appRoot: String
        public var installRoot: String
        public var logRoot: String?
        public init(appRoot: String, installRoot: String, logRoot: String? = nil) {
            self.appRoot = appRoot; self.installRoot = installRoot; self.logRoot = logRoot
        }
    }
    public struct ResourceCounts: Codable, Hashable, Sendable {
        public var containersRunning: Int
        public var containersTotal: Int
        public var images: Int
        public init(containersRunning: Int, containersTotal: Int, images: Int) {
            self.containersRunning = containersRunning; self.containersTotal = containersTotal; self.images = images
        }
    }

    public init(
        status: String, client: Component? = nil, server: Component? = nil, host: Host? = nil,
        paths: Paths? = nil, resources: ResourceCounts? = nil
    ) {
        self.status = status; self.client = client; self.server = server; self.host = host; self.paths = paths;
        self.resources = resources
    }

    public var isRunning: Bool { status == "running" }
    /// Used when the apiserver is down: the CLI still reports its own version.
    public static func stopped(clientVersion: String?) -> SystemStatus {
        SystemStatus(status: "stopped", client: clientVersion.map { Component(appName: "container", version: $0) })
    }
}

/// `container system df --format json`.
public struct DiskUsage: Codable, Hashable, Sendable {
    public var containers: Bucket
    public var images: Bucket
    public var volumes: Bucket

    public struct Bucket: Codable, Hashable, Sendable {
        public var total: Int
        public var active: Int
        public var sizeInBytes: Int64
        public var reclaimable: Int64
        public init(total: Int, active: Int, sizeInBytes: Int64, reclaimable: Int64) {
            self.total = total; self.active = active; self.sizeInBytes = sizeInBytes; self.reclaimable = reclaimable
        }

        public static let empty = Bucket(total: 0, active: 0, sizeInBytes: 0, reclaimable: 0)

        /// Missing counters read as 0.
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            total = (try? c.decodeIfPresent(Int.self, forKey: .total)) ?? 0
            active = (try? c.decodeIfPresent(Int.self, forKey: .active)) ?? 0
            sizeInBytes = (try? c.decodeIfPresent(Int64.self, forKey: .sizeInBytes)) ?? 0
            reclaimable = (try? c.decodeIfPresent(Int64.self, forKey: .reclaimable)) ?? 0
        }
    }

    public init(containers: Bucket, images: Bucket, volumes: Bucket) {
        self.containers = containers; self.images = images; self.volumes = volumes
    }

    /// A missing or unreadable bucket reads as empty.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        containers = (try? c.decodeIfPresent(Bucket.self, forKey: .containers)) ?? .empty
        images = (try? c.decodeIfPresent(Bucket.self, forKey: .images)) ?? .empty
        volumes = (try? c.decodeIfPresent(Bucket.self, forKey: .volumes)) ?? .empty
    }

    public var totalBytes: Int64 { containers.sizeInBytes + images.sizeInBytes + volumes.sizeInBytes }
    public var reclaimableBytes: Int64 { containers.reclaimable + images.reclaimable + volumes.reclaimable }
}

/// `container system property ls --format json` — the merged `config.toml`.
public struct SystemProperties: Codable, Hashable, Sendable {
    public var build: Build?
    public var container: ContainerDefaults?
    public var dns: DNS?
    public var kernel: Kernel?
    public var machine: Machine?
    public var network: NetworkDefaults?
    public var registry: Registry?
    public var vminit: VMInit?

    public struct Build: Codable, Hashable, Sendable {
        public var cpus: Int?; public var memory: String?; public var rosetta: Bool?; public var image: String?
    }
    public struct ContainerDefaults: Codable, Hashable, Sendable { public var cpus: Int?; public var memory: String? }
    public struct DNS: Codable, Hashable, Sendable { public var domain: String? }
    public struct Kernel: Codable, Hashable, Sendable {
        public var binaryPath: String?; public var url: String?; public var digest: String?
    }
    public struct Machine: Codable, Hashable, Sendable {
        public var cpus: Int?; public var memory: String?; public var homeMount: String?;
        public var virtualization: Bool?
    }
    public struct NetworkDefaults: Codable, Hashable, Sendable {
        public var subnet: String?; public var subnetv6: String?
    }
    public struct Registry: Codable, Hashable, Sendable { public var domain: String? }
    public struct VMInit: Codable, Hashable, Sendable { public var image: String? }

    public init() {}
}

/// A row of `container system dns ls`.
public struct DNSDomain: Codable, Identifiable, Hashable, Sendable {
    public var id: String { domain }
    public var domain: String
    /// Set when created with `--localhost <ip>`.
    public var localhostAddress: String?
    public init(domain: String, localhostAddress: String? = nil) {
        self.domain = domain; self.localhostAddress = localhostAddress
    }
}

// MARK: - Registries

/// A row of `container registry ls`. Credentials live in the Keychain; never surfaced.
public struct RegistryLogin: Codable, Identifiable, Hashable, Sendable {
    public var id: String { server }
    public var server: String
    public var username: String?
    public var scheme: String?
    public init(server: String, username: String? = nil, scheme: String? = nil) {
        self.server = server; self.username = username; self.scheme = scheme
    }
}

// MARK: - Machines

/// `container machine ls --format json` element (1.5.0 shape).
public struct Machine: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var status: MachineState
    public var cpus: Int
    public var memory: Int64
    public var diskSize: Int64
    public var isDefault: Bool
    public var createdDate: Date?
    public var image: ImageReference?
    public var homeMount: String?
    public var platform: Platform?
    public var userSetup: UserSetup?

    public struct UserSetup: Codable, Hashable, Sendable {
        public var username: String; public var uid: Int; public var gid: Int
        public init(username: String, uid: Int, gid: Int) { self.username = username; self.uid = uid; self.gid = gid }
    }

    enum CodingKeys: String, CodingKey {
        case id, status, cpus, memory, diskSize, isDefault = "default", createdDate, image, homeMount, platform,
            userSetup
    }

    public init(
        id: String, status: MachineState, cpus: Int, memory: Int64, diskSize: Int64, isDefault: Bool,
        createdDate: Date? = nil, image: ImageReference? = nil, homeMount: String? = "rw",
        platform: Platform? = .arm64, userSetup: UserSetup? = nil
    ) {
        self.id = id; self.status = status; self.cpus = cpus; self.memory = memory; self.diskSize = diskSize
        self.isDefault = isDefault; self.createdDate = createdDate; self.image = image; self.homeMount = homeMount
        self.platform = platform; self.userSetup = userSetup
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        status = try c.decode(MachineState.self, forKey: .status)
        cpus = try c.decode(Int.self, forKey: .cpus)
        memory = try c.decode(Int64.self, forKey: .memory)
        diskSize = try c.decodeIfPresent(Int64.self, forKey: .diskSize) ?? 0
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        createdDate = try c.decodeIfPresent(Date.self, forKey: .createdDate)
        image = try c.decodeIfPresent(ImageReference.self, forKey: .image)
        homeMount = try c.decodeIfPresent(String.self, forKey: .homeMount)
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform)
        userSetup = try c.decodeIfPresent(UserSetup.self, forKey: .userSetup)
    }

    public var name: String { id }
    public var isRunning: Bool { status == .running }
}

public enum MachineState: String, Codable, Hashable, Sendable {
    case running, stopped, unknown
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MachineState(rawValue: raw) ?? .unknown
    }
}

// MARK: - Kubernetes

/// A local cluster (`container k8s`). Nodes are containers; the CLI prints a table (no JSON in 1.5.0),
/// so backends may either parse the table or derive clusters from labelled containers.
public struct KubernetesCluster: Codable, Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var nodes: [Node]

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

// MARK: - Progress / output events

/// One line of streamed output from a long-running CLI action (pull, push, build, k8s create…).
public struct OutputLine: Hashable, Sendable {
    public enum Stream: Sendable { case stdout, stderr }
    public var stream: Stream
    public var text: String
    public var timestamp: Date
    public init(_ text: String, stream: Stream = .stdout, timestamp: Date = .now) {
        self.text = text; self.stream = stream; self.timestamp = timestamp
    }
}
