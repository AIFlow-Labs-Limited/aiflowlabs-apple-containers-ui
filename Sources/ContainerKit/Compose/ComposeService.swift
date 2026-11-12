import Foundation

/// One entry of `services:` — only the keys the app maps onto `container run` / `container build`.
public struct ComposeService: Hashable, Sendable, Identifiable {
    /// Key under `services:`.
    public var name: String
    /// `image:`.
    public var image: String?
    /// `build:` (short or long form).
    public var build: ComposeBuild?
    /// `container_name:`.
    public var containerName: String?
    /// `command:`.
    public var command: ComposeCommand?
    /// `entrypoint:`.
    public var entrypoint: ComposeCommand?
    /// `environment:` as `KEY=VALUE`, or a bare `KEY` (value taken from the host environment), in file order.
    public var environment: [String] = []
    /// `env_file:` entries, paths as written.
    public var envFiles: [ComposeEnvFile] = []
    /// `ports:` (ranges already expanded to single ports).
    public var ports: [ComposePort] = []
    /// `volumes:` plus service-level `tmpfs:`.
    public var mounts: [ComposeMount] = []
    /// `networks:` keys, in file order. Empty means the project's default network.
    public var networks: [String] = []
    /// `depends_on:`.
    public var dependsOn: [ComposeDependency] = []
    /// `working_dir:`.
    public var workingDirectory: String?
    /// `user:`.
    public var user: String?
    /// `labels:`.
    public var labels: [String: String] = [:]
    /// `cpus:` / `cpu_count:` / `deploy.resources.limits.cpus` (may be fractional, as written).
    public var cpus: Double?
    /// `mem_limit:` / `deploy.resources.limits.memory`.
    public var memory: MemorySize?
    /// `platform:` (`linux/amd64`).
    public var platform: String?
    /// `init:`.
    public var useInit = false
    /// `read_only:`.
    public var readOnly = false
    /// `tty:`.
    public var tty = false
    /// `stdin_open:`.
    public var stdinOpen = false
    /// `dns:` nameservers.
    public var dns: [String] = []
    /// `dns_search:` domains.
    public var dnsSearch: [String] = []
    /// `dns_opt:` options.
    public var dnsOptions: [String] = []
    /// `cap_add:`.
    public var capAdd: [String] = []
    /// `cap_drop:`.
    public var capDrop: [String] = []
    /// `shm_size:`.
    public var shmSize: MemorySize?
    /// `ulimits:` as `name=soft[:hard]`.
    public var ulimits: [String] = []
    /// `mac_address:`.
    public var macAddress: String?
    /// `profiles:`. A service with profiles only starts when one of them is enabled.
    public var profiles: [String] = []
    /// `healthcheck:`; `nil` when the service has none.
    public var healthcheck: ComposeHealthcheckSetting?
    /// `restart:` (`.no` when absent). Stored as a label and enforced by the app.
    public var restart: RestartPolicy = .no

    public var id: String { name }

    /// A service called `name` with nothing set.
    public init(name: String) { self.name = name }
}

/// `command:` / `entrypoint:` — compose accepts a shell-style string or an exec-style list.
public enum ComposeCommand: Hashable, Sendable {
    /// A single string, to be split like a shell would (`npm run start`).
    case shell(String)
    /// A list of words, used as-is.
    case exec([String])
}

/// `build:`.
public struct ComposeBuild: Hashable, Sendable {
    /// `context:` as written (relative to the compose file).
    public var context: String
    /// `dockerfile:` as written (relative to the context).
    public var dockerfile: String?
    /// `args:` as `KEY=VALUE` (or a bare `KEY`).
    public var args: [String] = []
    /// `target:`.
    public var target: String?
    /// `labels:` as `KEY=VALUE`.
    public var labels: [String] = []
    /// `platforms:`.
    public var platforms: [String] = []
    /// `no_cache:`.
    public var noCache = false
    /// `pull:`.
    public var pull = false

    /// A build of `context` with the default Dockerfile.
    public init(context: String) { self.context = context }
}

/// One `env_file:` entry.
public struct ComposeEnvFile: Hashable, Sendable {
    /// Path as written (relative to the compose file).
    public var path: String
    /// `required: false` lets the file be missing.
    public var isRequired = true

    /// An env file at `path`.
    public init(path: String, isRequired: Bool = true) {
        self.path = path
        self.isRequired = isRequired
    }
}

/// One published port.
public struct ComposePort: Hashable, Sendable {
    /// Host interface (`127.0.0.1`), when the file names one.
    public var hostAddress: String?
    /// Host port; `nil` when the file only names the container port (Docker picks a random host port).
    public var published: Int?
    /// Container port.
    public var target: Int
    /// `tcp` or `udp`.
    public var proto: String

    /// A mapping from `published` on the host to `target` in the container.
    public init(hostAddress: String? = nil, published: Int?, target: Int, proto: String = "tcp") {
        self.hostAddress = hostAddress
        self.published = published
        self.target = target
        self.proto = proto
    }
}

/// One `volumes:` entry of a service (or a `tmpfs:` path).
public struct ComposeMount: Hashable, Sendable {
    /// Where the data comes from.
    public enum Source: Hashable, Sendable {
        /// A host path as written (absolute, `./relative` or `~/home`).
        case bind(String)
        /// A named volume: the key under top-level `volumes:`.
        case volume(String)
        /// A volume with no name (`- /data`).
        case anonymous
        /// An in-memory filesystem, with an optional size.
        case tmpfs(size: MemorySize?)
    }

    public var source: Source
    /// Path inside the container.
    public var target: String
    public var readOnly: Bool

    /// A mount of `source` at `target`.
    public init(source: Source, target: String, readOnly: Bool = false) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
    }
}

/// One `depends_on:` entry.
public struct ComposeDependency: Hashable, Sendable {
    /// The service that must start first.
    public var service: String
    /// `service_started` (default), `service_healthy` or `service_completed_successfully`.
    public var condition: String

    /// The dependency has been started (the default).
    public static let started = "service_started"
    /// The dependency's health check has passed.
    public static let healthy = "service_healthy"
    /// The dependency has run to completion.
    public static let completedSuccessfully = "service_completed_successfully"
    /// The conditions Compose defines.
    public static let knownConditions: Set<String> = [started, healthy, completedSuccessfully]

    /// A dependency on `service`.
    public init(service: String, condition: String = ComposeDependency.started) {
        self.service = service
        self.condition = condition
    }
}
