import ContainerKit
import Foundation

// Display strings for clusters, kept out of the views so they can be unit-tested.

extension KubernetesCluster {
    /// `Running`, `Stopped`, `Unknown` or `Degraded (2 of 3 up)`.
    public var stateTitle: String {
        let text = stateDescription
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// `1 node`, or `1 control plane + 2 workers` when the cluster has dedicated workers.
    public var nodesSummary: String {
        let workers = workerNodes.count
        guard workers > 0 else { return nodes.count == 1 ? "1 node" : "\(nodes.count) nodes" }
        let controlPlanes = nodes.count - workers
        return
            "\(controlPlanes) control plane\(controlPlanes == 1 ? "" : "s") + \(workers) worker\(workers == 1 ? "" : "s")"
    }

    /// The pod network: `kindnet (built in)` by default, `None` for `--cni NONE`, else the manifest's file name.
    public var cniTitle: String {
        guard let cni, !cni.isEmpty else { return "kindnet (built in)" }
        if cni.uppercased() == "NONE" { return "None" }
        return URL(fileURLWithPath: cni).lastPathComponent
    }
}

extension KubernetesCluster.Node {
    /// `4 CPUs · 8 GB`; `nil` when the CLI did not report a size (the node's container no longer exists).
    public var sizeText: String? {
        guard cpus > 0 || memoryMB > 0 else { return nil }
        let memory = memoryMB % 1024 == 0 ? "\(memoryMB / 1024) GB" : "\(memoryMB) MB"
        return "\(cpus) CPU\(cpus == 1 ? "" : "s") · \(memory)"
    }
}
