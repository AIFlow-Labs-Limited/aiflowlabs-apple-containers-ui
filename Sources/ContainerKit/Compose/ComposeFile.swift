import Foundation

/// A parsed `compose.yaml` / `docker-compose.yml`: the subset this app can run, plus a warning for everything
/// it read but cannot honour. Produced by `ComposeParser`; turned into commands by AppCore's `ComposePlanner`.
public struct ComposeFile: Hashable, Sendable {
    /// Top-level `name:` (the project name), when the file sets one.
    public var name: String?
    /// Services in file order.
    public var services: [ComposeService] = []
    /// Top-level `volumes:` in file order.
    public var volumes: [ComposeVolume] = []
    /// Top-level `networks:` in file order.
    public var networks: [ComposeNetwork] = []
    /// Keys that were read but are not supported, and values handled differently from Docker Compose.
    public var warnings: [ComposeWarning] = []
    /// Variables referenced without a value and without a default (they interpolate to an empty string).
    public var unsetVariables: [String] = []

    /// An empty file.
    public init() {}

    /// The service called `name`.
    public func service(named name: String) -> ComposeService? { services.first { $0.name == name } }

    /// Every profile any service declares, sorted.
    public var profiles: [String] { Set(services.flatMap(\.profiles)).sorted() }

    /// Warnings for one scope, in the order they were found.
    public func warnings(for scope: ComposeWarning.Scope) -> [ComposeWarning] { warnings.filter { $0.scope == scope } }
}

/// A top-level `volumes:` entry.
public struct ComposeVolume: Hashable, Sendable, Identifiable {
    /// Key under `volumes:` (what services reference).
    public var key: String
    /// Explicit `name:`; when `nil` the volume is created as `<project>_<key>`.
    public var name: String?
    /// `external: true`: the volume must already exist and is never created.
    public var isExternal = false
    /// `labels:`.
    public var labels: [String: String] = [:]

    public var id: String { key }

    /// A volume declared under `key`.
    public init(key: String) { self.key = key }
}

/// A top-level `networks:` entry.
public struct ComposeNetwork: Hashable, Sendable, Identifiable {
    /// Key under `networks:` (what services reference).
    public var key: String
    /// Explicit `name:`; when `nil` the network is created as `<project>_<key>`.
    public var name: String?
    /// `external: true`: the network must already exist and is never created.
    public var isExternal = false
    /// First IPv4 subnet of `ipam.config`.
    public var subnet: String?
    /// First IPv6 subnet of `ipam.config`.
    public var subnetV6: String?
    /// `labels:`.
    public var labels: [String: String] = [:]

    public var id: String { key }

    /// A network declared under `key`.
    public init(key: String) { self.key = key }
}

/// Something in the compose file the app cannot honour exactly. Never an error: the import still works, the
/// preview lists these so the user knows what will differ from `docker compose up`.
public struct ComposeWarning: Hashable, Sendable, Identifiable {
    /// What the warning is about.
    public enum Scope: Hashable, Sendable {
        case file
        case service(String)
        case volume(String)
        case network(String)
    }

    /// How serious the difference is.
    public enum Severity: String, Hashable, Sendable {
        /// The key is ignored: the stack runs without it.
        case unsupported
        /// The key is honoured, with a difference worth knowing.
        case note
    }

    public var scope: Scope
    /// The compose key (`restart`, `healthcheck`, `deploy.replicas`, …).
    public var key: String
    public var message: String
    public var severity: Severity

    public var id: String { "\(scope)|\(key)|\(message)" }

    /// A warning about `key` in `scope`.
    public init(scope: Scope, key: String, message: String, severity: Severity = .unsupported) {
        self.scope = scope
        self.key = key
        self.message = message
        self.severity = severity
    }
}

/// Why a compose file could not be read at all.
public enum ComposeError: Error, LocalizedError, Hashable, Sendable {
    /// The text is not valid YAML. `message` carries the parser's position and reason.
    case invalidYAML(String)
    /// Valid YAML that is not a compose file (no `services:` mapping, a service that is not a mapping, …).
    case invalidStructure(String)
    /// `${NAME:?message}` / `${NAME?message}` with `NAME` unset (or empty for `:?`).
    case requiredVariable(name: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidYAML(let message): return "This file is not valid YAML: \(message)"
        case .invalidStructure(let message): return message
        case .requiredVariable(let name, let message):
            return message.isEmpty
                ? "The variable \(name) is required but has no value."
                : "The variable \(name) is required: \(message)"
        }
    }
}
