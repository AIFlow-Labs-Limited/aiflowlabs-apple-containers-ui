import Foundation

// MARK: - KubernetesOperations

extension CLIBackend {
    /// `container k8s --help`: `true` when it exits 0, `false` only when the plugin is missing
    /// (`unknown command 'k8s'` / `Plugins are unavailable` while `system status` succeeds).
    /// Throws `.systemNotRunning` when the system is down, and any other failure as mapped.
    public func checkKubernetesAvailable() async throws -> Bool {
        let arguments = ["k8s", "--help"]
        let result = try await runRaw(arguments, timeout: .seconds(15))
        if result.exitCode == 0 { return true }
        let raw = result.stderrText + result.stdoutText
        if CLIErrorMapper.indicatesSystemNotRunning(raw) { throw BackendError.systemNotRunning }
        if raw.localizedCaseInsensitiveContains("unknown command") || CLIErrorMapper.isPluginsUnavailable(raw) {
            // Both messages are also printed when services are down; ask `system status` to tell them apart.
            let status = try? await runner.run(
                [executable, "system", "status"], stdin: nil, timeout: .seconds(15), environment: [:])
            if status?.exitCode == 0 { return false }
            throw BackendError.systemNotRunning
        }
        throw await failure(arguments, result)
    }

    /// Compatibility shim: `checkKubernetesAvailable()` with every error read as `false`.
    public func kubernetesAvailable() async -> Bool {
        (try? await checkKubernetesAvailable()) ?? false
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
            return failedStream(
                .unsupported(
                    feature: "Kubernetes worker nodes",
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
    public nonisolated func loadImage(
        _ reference: String, intoCluster cluster: String?, nodes: [String], platform: Platform?
    ) -> LineStream {
        guard nodes.isEmpty else {
            return failedStream(
                .unsupported(
                    feature: "Loading an image into specific nodes",
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
