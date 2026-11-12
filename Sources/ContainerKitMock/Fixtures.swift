import ContainerKit
import Foundation

/// One folder of output **recorded** from a real `container` CLI by `scripts/record-fixtures.sh`
/// (`Resources/cli-<version>/`). JSON files are pretty-printed with sorted keys; `.txt` and `.compact.json` files
/// are byte for byte what the CLI printed.
public struct FixtureSet: Sendable {
    /// The CLI release the folder was recorded from.
    public let cliVersion: String

    /// Recorded from CLI 1.5.0 on macOS 26.6.2: the `k8s` plugin, no `commit`, no `cpuUtilization`.
    public static let cli150 = FixtureSet(cliVersion: "1.5.0")
    /// Recorded from CLI 1.7.1 on macOS 27.2 on 2026-11-12: the `cluster` plugin with a two-node cluster
    /// (`cluster-list*.json/.txt`; `-degraded` and `-stopped` variants of the same cluster; `-single` and
    /// `-removed` for a one-node `--rm` cluster before and after its node went away), `commit`, `clean`, stats
    /// with `cpuUtilization`.
    public static let cli171 = FixtureSet(cliVersion: "1.7.1")

    var folder: String { "cli-\(cliVersion)" }

    public func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: folder) else {
            preconditionFailure("Missing fixture \(folder)/\(name)")
        }
        return url
    }

    /// Whether the folder has a file of that name (not every release records every file).
    public func has(_ name: String) -> Bool {
        Bundle.module.url(forResource: name, withExtension: nil, subdirectory: folder) != nil
    }

    public func data(_ name: String) -> Data {
        guard let d = try? Data(contentsOf: url(name)) else { preconditionFailure("Unreadable fixture \(name)") }
        return d
    }

    public func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }

    public func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try CLIJSON.decode(type, from: data(name))
    }

    public func containers() throws -> [Container] { try decode([Container].self, "containers.json") }
    public func images() throws -> [Image] { try decode([Image].self, "images.json") }
    public func volumes() throws -> [Volume] { try decode([Volume].self, "volumes.json") }
    public func networks() throws -> [Network] { try decode([Network].self, "networks.json") }
    public func stats() throws -> [ContainerStats] { try decode([ContainerStats].self, "stats.json") }
    public func machines() throws -> [Machine] { try decode([Machine].self, "machines.json") }
    public func builder() throws -> [Container] { try decode([Container].self, "builder.json") }
    public func diskUsage() throws -> DiskUsage { try decode(DiskUsage.self, "system-df.json") }
    public func systemStatus() throws -> SystemStatus { try decode(SystemStatus.self, "system-status.json") }
    public func systemProperties() throws -> SystemProperties {
        try decode(SystemProperties.self, "system-properties.json")
    }

    /// `container cluster list --format json` (`variant`: `nil`, `degraded`, `stopped`, `single` or `removed`). 1.7.1 only.
    public func clusterResources(variant: String? = nil) throws -> [ClusterResource] {
        try decode([ClusterResource].self, "cluster-list\(Self.suffix(variant)).json")
    }

    /// `container cluster list --nodes`, parsed (per-node CPU and memory). 1.7.1 only.
    public func clusterNodeTable(variant: String? = nil) -> [KubernetesCluster] {
        CLIOutputParsing.clusters(text("cluster-list-nodes\(Self.suffix(variant)).txt"))
    }

    /// The recorded clusters as the app shows them: the JSON records merged with the node table. 1.7.1 only.
    public func clusters(variant: String? = nil) throws -> [KubernetesCluster] {
        let table = clusterNodeTable(variant: variant)
        return try clusterResources(variant: variant).map { KubernetesCluster(resource: $0, nodeTable: table) }
    }

    private static func suffix(_ variant: String?) -> String { variant.map { "-\($0)" } ?? "" }
}

/// The 1.5.0 recording, which `MockBackend` and most decoder tests are built on. Shorthand for
/// `FixtureSet.cli150`; the 1.7.1 recording is `FixtureSet.cli171`.
public enum Fixtures {
    public static let cliVersion = FixtureSet.cli150.cliVersion

    public static func url(_ name: String) -> URL { FixtureSet.cli150.url(name) }
    public static func data(_ name: String) -> Data { FixtureSet.cli150.data(name) }
    public static func text(_ name: String) -> String { FixtureSet.cli150.text(name) }

    public static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try FixtureSet.cli150.decode(type, name)
    }

    public static func containers() throws -> [Container] { try FixtureSet.cli150.containers() }
    public static func images() throws -> [Image] { try FixtureSet.cli150.images() }
    public static func volumes() throws -> [Volume] { try FixtureSet.cli150.volumes() }
    public static func networks() throws -> [Network] { try FixtureSet.cli150.networks() }
    public static func stats() throws -> [ContainerStats] { try FixtureSet.cli150.stats() }
    public static func machines() throws -> [Machine] { try FixtureSet.cli150.machines() }
    public static func builder() throws -> [Container] { try FixtureSet.cli150.builder() }
    public static func diskUsage() throws -> DiskUsage { try FixtureSet.cli150.diskUsage() }
    public static func systemStatus() throws -> SystemStatus { try FixtureSet.cli150.systemStatus() }
    public static func systemProperties() throws -> SystemProperties { try FixtureSet.cli150.systemProperties() }
}
