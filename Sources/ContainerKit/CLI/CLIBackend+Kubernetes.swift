import Foundation

// MARK: - KubernetesOperations

extension CLIBackend {
    /// `container k8s --help` exits 0 only when the plugin exists and the system is running.
    public func kubernetesAvailable() async -> Bool {
        (try? await runRaw(["k8s", "--help"], timeout: .seconds(15)))?.exitCode == 0
    }

    /// `container k8s ls` (table only in 1.5.0), grouped into clusters.
    public func listClusters() async throws -> [KubernetesCluster] {
        let result = try await execute(["k8s", "ls"])
        return CLIOutputParsing.clusters(result.stdoutText)
    }

    /// `container k8s create --name N [-c N] [-m SIZE] [--node-image REF] [--cni FILE] [--rm]`.
    /// Worker nodes are not supported by CLI 1.5.0.
    public nonisolated func createCluster(_ spec: ClusterSpec) -> LineStream {
        if let workers = spec.workers, workers > 0 {
            return failedStream(.unsupported(feature: "Kubernetes worker nodes",
                                             reason: "`container k8s create` has no --workers option in this CLI version."))
        }
        return validatedStream {
            try Self.validateOperand(spec.name, "Cluster name")
            return streamCommand(["k8s", "create"] + spec.cliArguments)
        }
    }

    /// `container k8s delete --name NAME`.
    public func deleteCluster(_ name: String) async throws {
        try Self.validateOperand(name, "Cluster name")
        try await execute(["k8s", "delete", "--name", name], timeout: .seconds(300))
    }

    /// `container k8s load-image [--name CLUSTER] [--platform P] -- REF`. Per-node targeting is not supported
    /// by CLI 1.5.0 (the image is loaded into every node).
    public nonisolated func loadImage(_ reference: String, intoCluster cluster: String?, nodes: [String], platform: Platform?) -> LineStream {
        guard nodes.isEmpty else {
            return failedStream(.unsupported(feature: "Loading an image into specific nodes",
                                             reason: "`container k8s load-image` has no --node option in this CLI version."))
        }
        return validatedStream {
            try Self.validateOperand(reference, "Image reference")
            if let cluster { try Self.validateOperand(cluster, "Cluster name") }
            var arguments = ["k8s", "load-image"]
            if let cluster { arguments += ["--name", cluster] }
            if let platform { arguments += ["--platform", platform.slug] }
            arguments += ["--", reference]
            return streamCommand(arguments)
        }
    }
}
