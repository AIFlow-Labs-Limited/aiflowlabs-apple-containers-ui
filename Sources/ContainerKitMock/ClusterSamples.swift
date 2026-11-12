import ContainerKit
import Foundation

/// Hand-written cluster scenarios in the shape of container 1.7.1's output (`Resources/samples-1.7/`): a running
/// single-node cluster, a degraded three-node one with the shared image store, and a stopped one without a CNI.
///
/// These are **samples, not recordings**. They exist because one engine rarely has all three situations at once,
/// and the mock and the presentation tests want them side by side. The recorded truth is `FixtureSet.cli171`
/// (`Resources/cli-1.7.1/`); a test checks that the samples use no key the recording does not have.
public enum ClusterSamples {
    static let folder = "samples-1.7"

    public static func url(_ name: String) -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: folder) else {
            preconditionFailure("Missing sample \(name)")
        }
        return url
    }

    public static func data(_ name: String) -> Data {
        guard let d = try? Data(contentsOf: url(name)) else { preconditionFailure("Unreadable sample \(name)") }
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
}
