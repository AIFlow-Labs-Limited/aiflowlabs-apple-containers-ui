import Foundation

/// A container as reported by `container ls -a --format json` / `container inspect`.
/// Field names mirror the CLI JSON so fixtures decode without translation.
public struct Container: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var configuration: Configuration
    public var status: Status?

    public init(id: String, configuration: Configuration, status: Status? = nil) {
        self.id = id
        self.configuration = configuration
        self.status = status
    }

    // MARK: Derived

    public var state: ContainerState { status?.state ?? .stopped }
    public var isRunning: Bool { state == .running }
    public var imageReference: String { configuration.image.reference }
    public var primaryIPv4: String? { status?.networks.first?.ipv4Address.split(separator: "/").first.map(String.init) }
    public var hostname: String? { status?.networks.first?.hostname }
    public var labels: [String: String] { configuration.labels }
    public var role: String? { labels[ResourceLabel.role] }
    /// The BuildKit builder, k8s nodes, etc. — hidden from the main list by default.
    public var isSystemManaged: Bool { role != nil || labels[ResourceLabel.plugin] != nil }
    public var isBuilder: Bool { role == ResourceLabel.Role.builder }
    /// `python3 -m http.server 8000`
    public var commandLine: String {
        ([configuration.initProcess.executable] + configuration.initProcess.arguments).joined(separator: " ")
    }

    // MARK: Nested types

    public struct Configuration: Codable, Hashable, Sendable {
        public var id: String
        public var image: ImageReference
        public var creationDate: Date
        public var platform: Platform
        public var resources: Resources
        public var initProcess: InitProcess
        public var labels: [String: String]
        public var mounts: [Mount]
        public var networks: [NetworkAttachment]
        public var publishedPorts: [PublishedPort]
        public var publishedSockets: [PublishedSocket]
        public var dns: DNSConfiguration?
        public var capAdd: [String]
        public var capDrop: [String]
        public var readOnly: Bool
        public var rosetta: Bool
        public var ssh: Bool
        public var useInit: Bool
        public var virtualization: Bool
        public var runtimeHandler: String?
        public var sysctls: [String: String]?

        public init(
            id: String, image: ImageReference, creationDate: Date, platform: Platform = .arm64,
            resources: Resources = Resources(cpus: 4, memoryInBytes: 1 << 30),
            initProcess: InitProcess, labels: [String: String] = [:], mounts: [Mount] = [],
            networks: [NetworkAttachment] = [], publishedPorts: [PublishedPort] = [],
            publishedSockets: [PublishedSocket] = [], dns: DNSConfiguration? = nil,
            capAdd: [String] = [], capDrop: [String] = [], readOnly: Bool = false, rosetta: Bool = false,
            ssh: Bool = false, useInit: Bool = false, virtualization: Bool = false,
            runtimeHandler: String? = nil, sysctls: [String: String]? = nil
        ) {
            self.id = id; self.image = image; self.creationDate = creationDate; self.platform = platform
            self.resources = resources; self.initProcess = initProcess; self.labels = labels; self.mounts = mounts
            self.networks = networks; self.publishedPorts = publishedPorts; self.publishedSockets = publishedSockets
            self.dns = dns; self.capAdd = capAdd; self.capDrop = capDrop; self.readOnly = readOnly
            self.rosetta = rosetta; self.ssh = ssh; self.useInit = useInit; self.virtualization = virtualization
            self.runtimeHandler = runtimeHandler; self.sysctls = sysctls
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            image = try c.decode(ImageReference.self, forKey: .image)
            creationDate = try c.decode(Date.self, forKey: .creationDate)
            platform = try c.decodeIfPresent(Platform.self, forKey: .platform) ?? .arm64
            resources = try c.decode(Resources.self, forKey: .resources)
            initProcess = try c.decode(InitProcess.self, forKey: .initProcess)
            labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
            mounts = try c.decodeIfPresent([Mount].self, forKey: .mounts) ?? []
            networks = try c.decodeIfPresent([NetworkAttachment].self, forKey: .networks) ?? []
            publishedPorts = try c.decodeIfPresent([PublishedPort].self, forKey: .publishedPorts) ?? []
            publishedSockets = try c.decodeIfPresent([PublishedSocket].self, forKey: .publishedSockets) ?? []
            dns = try c.decodeIfPresent(DNSConfiguration.self, forKey: .dns)
            capAdd = try c.decodeIfPresent([String].self, forKey: .capAdd) ?? []
            capDrop = try c.decodeIfPresent([String].self, forKey: .capDrop) ?? []
            readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
            rosetta = try c.decodeIfPresent(Bool.self, forKey: .rosetta) ?? false
            ssh = try c.decodeIfPresent(Bool.self, forKey: .ssh) ?? false
            useInit = try c.decodeIfPresent(Bool.self, forKey: .useInit) ?? false
            virtualization = try c.decodeIfPresent(Bool.self, forKey: .virtualization) ?? false
            runtimeHandler = try c.decodeIfPresent(String.self, forKey: .runtimeHandler)
            sysctls = try c.decodeIfPresent([String: String].self, forKey: .sysctls)
        }
    }

    public struct Resources: Codable, Hashable, Sendable {
        public var cpus: Int
        public var memoryInBytes: Int64
        public var cpuOverhead: Int?

        public init(cpus: Int, memoryInBytes: Int64, cpuOverhead: Int? = nil) {
            self.cpus = cpus
            self.memoryInBytes = memoryInBytes
            self.cpuOverhead = cpuOverhead
        }
    }

    public struct InitProcess: Codable, Hashable, Sendable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String]
        public var workingDirectory: String?
        public var terminal: Bool
        public var user: User?

        public init(
            executable: String, arguments: [String] = [], environment: [String] = [],
            workingDirectory: String? = "/", terminal: Bool = false, user: User? = nil
        ) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.terminal = terminal
            self.user = user
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            executable = try c.decode(String.self, forKey: .executable)
            arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? []
            environment = try c.decodeIfPresent([String].self, forKey: .environment) ?? []
            workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
            terminal = try c.decodeIfPresent(Bool.self, forKey: .terminal) ?? false
            user = try c.decodeIfPresent(User.self, forKey: .user)
        }

        /// `{"id": {"uid": 0, "gid": 0}}` or `{"raw": {"userString": "name:gid"}}`.
        public struct User: Codable, Hashable, Sendable {
            public var id: IDPair?
            public var raw: Raw?
            public struct IDPair: Codable, Hashable, Sendable { public var uid: Int; public var gid: Int }
            public struct Raw: Codable, Hashable, Sendable { public var userString: String }
            public var display: String { id.map { "\($0.uid):\($0.gid)" } ?? raw?.userString ?? "root" }
        }
    }

    public struct Mount: Codable, Hashable, Sendable {
        public var destination: String
        public var source: String
        public var options: [String]
        public var type: MountType

        public init(destination: String, source: String, options: [String] = [], type: MountType) {
            self.destination = destination
            self.source = source
            self.options = options
            self.type = type
        }

        public var isReadOnly: Bool { options.contains("ro") }
    }

    /// `{"volume": {"name": …}}`, `{"virtiofs": {}}`, `{"tmpfs": {…}}`, or something newer.
    public enum MountType: Codable, Hashable, Sendable {
        case volume(name: String, format: String?)
        case bind
        case tmpfs(options: [String: JSONValue])
        case other(kind: String)

        public var kind: String {
            switch self {
            case .volume: return "volume"
            case .bind: return "bind"
            case .tmpfs: return "tmpfs"
            case .other(let k): return k
            }
        }

        public var volumeName: String? { if case .volume(let n, _) = self { return n } else { return nil } }

        private struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            guard let key = c.allKeys.first else { self = .other(kind: "unknown"); return }
            switch key.stringValue {
            case "volume":
                let v = try c.decode([String: JSONValue].self, forKey: key)
                self = .volume(name: v["name"]?.stringValue ?? "", format: v["format"]?.stringValue)
            case "virtiofs", "bind":
                self = .bind
            case "tmpfs":
                self = .tmpfs(options: (try? c.decode([String: JSONValue].self, forKey: key)) ?? [:])
            default:
                self = .other(kind: key.stringValue)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            switch self {
            case .volume(let name, let format):
                var o: [String: JSONValue] = ["name": .string(name)]
                if let format { o["format"] = .string(format) }
                try c.encode(o, forKey: Key(stringValue: "volume"))
            case .bind: try c.encode([String: JSONValue](), forKey: Key(stringValue: "virtiofs"))
            case .tmpfs(let o): try c.encode(o, forKey: Key(stringValue: "tmpfs"))
            case .other(let k): try c.encode([String: JSONValue](), forKey: Key(stringValue: k))
            }
        }
    }

    public struct NetworkAttachment: Codable, Hashable, Sendable {
        public var network: String
        public var options: Options?
        public struct Options: Codable, Hashable, Sendable {
            public var hostname: String?
            public var mtu: Int?
            public var mac: String?
            public var aliases: [String]?
            public init(hostname: String? = nil, mtu: Int? = nil, mac: String? = nil, aliases: [String]? = nil) {
                self.hostname = hostname; self.mtu = mtu; self.mac = mac; self.aliases = aliases
            }
        }
        public init(network: String, options: Options? = nil) { self.network = network; self.options = options }
    }

    public struct PublishedPort: Codable, Hashable, Sendable {
        public var hostAddress: String
        public var hostPort: Int
        public var containerPort: Int
        public var proto: String
        public var count: Int?

        public init(
            hostAddress: String = "127.0.0.1", hostPort: Int, containerPort: Int, proto: String = "tcp", count: Int? = 1
        ) {
            self.hostAddress = hostAddress; self.hostPort = hostPort; self.containerPort = containerPort
            self.proto = proto; self.count = count
        }

        /// `127.0.0.1:18099->8000/tcp`
        public var display: String { "\(hostAddress):\(hostPort)->\(containerPort)/\(proto)" }
        /// `http://127.0.0.1:PORT`; wildcard hosts map to loopback and IPv6 hosts are bracketed (`http://[::1]:PORT`).
        public var hostURL: URL? {
            let host: String
            switch hostAddress {
            case "0.0.0.0", "": host = "127.0.0.1"
            case "::", "[::]": host = "[::1]"
            default: host = HostAddress.bracketed(hostAddress)
            }
            return URL(string: "http://\(host):\(hostPort)")
        }
    }

    public struct PublishedSocket: Codable, Hashable, Sendable {
        public var hostPath: String
        public var containerPath: String
        public init(hostPath: String, containerPath: String) {
            self.hostPath = hostPath; self.containerPath = containerPath
        }
    }

    public struct DNSConfiguration: Codable, Hashable, Sendable {
        public var domain: String?
        public var nameservers: [String]
        public var searchDomains: [String]
        public var options: [String]
        public init(
            domain: String? = nil, nameservers: [String] = [], searchDomains: [String] = [], options: [String] = []
        ) {
            self.domain = domain; self.nameservers = nameservers; self.searchDomains = searchDomains;
            self.options = options
        }
    }

    public struct Status: Codable, Hashable, Sendable {
        public var state: ContainerState
        public var startedDate: Date?
        public var networks: [NetworkStatus]

        public init(state: ContainerState, startedDate: Date? = nil, networks: [NetworkStatus] = []) {
            self.state = state
            self.startedDate = startedDate
            self.networks = networks
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decode(ContainerState.self, forKey: .state)
            startedDate = try c.decodeIfPresent(Date.self, forKey: .startedDate)
            networks = try c.decodeIfPresent([NetworkStatus].self, forKey: .networks) ?? []
        }
    }

    public struct NetworkStatus: Codable, Hashable, Sendable {
        public var network: String
        public var hostname: String?
        public var ipv4Address: String
        public var ipv4Gateway: String?
        public var ipv6Address: String?
        public var macAddress: String?
        public var mtu: Int?
        public var variant: String?

        public init(
            network: String = "default", hostname: String? = nil, ipv4Address: String,
            ipv4Gateway: String? = "192.168.64.1",
            ipv6Address: String? = nil, macAddress: String? = nil, mtu: Int? = nil, variant: String? = nil
        ) {
            self.network = network; self.hostname = hostname; self.ipv4Address = ipv4Address;
            self.ipv4Gateway = ipv4Gateway
            self.ipv6Address = ipv6Address; self.macAddress = macAddress; self.mtu = mtu; self.variant = variant
        }
    }
}

/// Container lifecycle state. Unknown strings decode as `.unknown` so a newer CLI never breaks the list.
public enum ContainerState: String, Codable, Hashable, Sendable, CaseIterable {
    case running, stopped, stopping, created, unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ContainerState(rawValue: raw) ?? .unknown
    }
}
