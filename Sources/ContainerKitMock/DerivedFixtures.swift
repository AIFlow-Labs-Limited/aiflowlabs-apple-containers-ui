import ContainerKit
import Foundation

/// Samples for container 1.7.1 that were **written from Apple's source code, not recorded** (see
/// `Resources/cli-1.7.1-derived/README.md`). Replace with `scripts/record-fixtures.sh` output once a 1.7 engine
/// is available; until then they back the 1.7-style mock and the decoder tests.
public enum DerivedFixtures {
    /// The CLI version the samples describe.
    public static let cliVersion = "1.7.1"
    static let folder = "cli-1.7.1-derived"

    public static func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: folder) else {
            preconditionFailure("Missing derived fixture \(name)")
        }
        return url
    }

    public static func data(_ name: String) -> Data {
        guard let d = try? Data(contentsOf: url(name)) else { preconditionFailure("Unreadable fixture \(name)") }
        return d
    }

    public static func text(_ name: String) -> String { String(decoding: data(name), as: UTF8.self) }

    /// `container cluster list --format json`.
    public static func clusterResources() throws -> [ClusterResource] {
        try CLIJSON.decode([ClusterResource].self, from: data("cluster-list.json"))
    }

    /// `container cluster list --nodes`, parsed (per-node CPU and memory).
    public static func clusterNodeTable() -> [KubernetesCluster] {
        CLIOutputParsing.clusters(text("cluster-list-nodes.txt"))
    }

    /// The clusters as the app shows them: the JSON records merged with the node table.
    public static func clusters() throws -> [KubernetesCluster] {
        let table = clusterNodeTable()
        return try clusterResources().map { KubernetesCluster(resource: $0, nodeTable: table) }
    }

    /// `container stats --no-stream --format json` with `cpuUtilization`.
    public static func stats() throws -> [ContainerStats] {
        try CLIJSON.decode([ContainerStats].self, from: data("stats.json"))
    }
}
