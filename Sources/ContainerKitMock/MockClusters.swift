import ContainerKit
import Foundation

/// Kubernetes behaviour of `MockBackend`, which can play an old plugin (`KubernetesCapabilities.legacy`:
/// container 1.5.0's `k8s`) or a new one (`.modern`: container 1.7's `cluster`).
enum MockClusters {
    /// Environment override for `make run-mock`: `CONTAINER_DESKTOP_MOCK_CLI=1.7` (or `modern`) plays the new
    /// plugin, `none` plays a CLI without the plugin; anything else plays 1.5.0.
    static let environmentVariable = "CONTAINER_DESKTOP_MOCK_CLI"

    static func environmentCapabilities(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> KubernetesCapabilities? {
        switch environment[environmentVariable]?.lowercased() {
        case "1.7", "1.7.1", "modern", "cluster": return .modern
        case "none": return nil
        default: return .legacy
        }
    }

    /// Clusters a mock starts with: none for the old plugin (as before), the derived 1.7.1 samples for the new one.
    static func seed(for capabilities: KubernetesCapabilities?) -> [KubernetesCluster] {
        guard capabilities?.listsJSON == true else { return [] }
        return (try? DerivedFixtures.clusters()) ?? []
    }

    /// `cpuUtilization` for the mock's stats: `nil` for the old CLI (which has no such field), else the rate curve
    /// behind the mock's `cpuUsageUsec` counter at `time`, in cores (the derivative of its closed-form integral).
    static func cpuUtilization(
        _ capabilities: KubernetesCapabilities?, index: Int, time: Double, phase: Double
    ) -> Double? {
        guard capabilities?.listsJSON == true else { return nil }
        let rate = Double(30_000 + index * 15_000)
        return rate * (1 + 0.7 * sin(time / 9 + phase) + 0.25 * sin(time / 3.7 + phase * 2)) / 1_000_000
    }

    /// What `create` prints, line by line.
    static func createLines(_ spec: ClusterSpec) -> [String] {
        var lines = ["Pulling node image kindest/node:v1.35.5", "Creating control-plane node \(spec.name)"]
        lines += (0..<spec.totalWorkers).map { "Creating worker node \(spec.name)-worker-\($0 + 1)" }
        lines += [
            "Initializing kubeadm", "Installing kindnet CNI", "Writing kubeconfig context \(spec.name)",
            "Cluster \(spec.name) is ready",
        ]
        return lines
    }

    /// The cluster `create` produces: one node, or a control plane plus `<name>-worker-<n>` nodes. A JSON-capable
    /// plugin also reports version, state and the shared image store.
    static func cluster(for spec: ClusterSpec, capabilities: KubernetesCapabilities) -> KubernetesCluster {
        let defaultMemoryMB: Int64 = 4096
        let workers = spec.effectiveWorkerGroups.flatMap { group in
            Array(repeating: group, count: group.count)
        }
        var nodes = [
            KubernetesCluster.Node(
                name: spec.name, role: workers.isEmpty ? "control-plane,worker" : "control-plane", state: .running,
                cpus: spec.cpus ?? 4, memoryMB: spec.memory.map { $0.bytes >> 20 } ?? defaultMemoryMB,
                address: "192.168.64.70", ports: "6443->6443")
        ]
        for (index, group) in workers.enumerated() {
            nodes.append(
                KubernetesCluster.Node(
                    name: "\(spec.name)-worker-\(index + 1)", role: "worker", state: .running,
                    cpus: group.cpus ?? 4, memoryMB: group.memory.map { $0.bytes >> 20 } ?? defaultMemoryMB,
                    address: "192.168.64.\(71 + index)"))
        }
        var cluster = KubernetesCluster(name: spec.name, nodes: nodes)
        if capabilities.listsJSON {
            cluster.kubernetesVersion = kubernetesVersion(nodeImage: spec.nodeImage)
            cluster.reportedState = .running
            cluster.sharedImageStore = spec.sharedImageStore
            cluster.cni = spec.cniManifest
            cluster.removeOnStop = spec.removeOnStop
            cluster.creationDate = .now
        }
        return cluster
    }

    /// The tag of the node image (`docker.io/kindest/node:v1.34.11@sha256:…` → `v1.34.11`).
    static func kubernetesVersion(nodeImage: String?) -> String {
        guard let image = nodeImage?.split(separator: "@").first,
            let colon = image.lastIndex(of: ":"), !image[colon...].contains("/")
        else { return "v1.35.5" }
        return String(image[image.index(after: colon)...])
    }
}
