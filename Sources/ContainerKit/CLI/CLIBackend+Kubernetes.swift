import Foundation

// MARK: - KubernetesOperations

// The plugin changed between CLI releases (`k8s` in 1.5/1.6.0, `cluster` from 1.6.1; JSON listing, worker groups
// and the shared image store in 1.7, which also dropped `load-image`). Nothing here checks a version number:
// every command is built from `KubernetesCapabilities`, detected once from the plugin's own `--help`.
extension CLIBackend {
    /// `true` when the Kubernetes plugin exists, `false` only when it is missing (`unknown command` /
    /// `Plugins are unavailable` for both `cluster` and `k8s` while `system status` succeeds).
    /// Throws `.systemNotRunning` when the system is down, and any other failure as mapped.
    public func checkKubernetesAvailable() async throws -> Bool {
        try await kubernetesCapabilities() != nil
    }

    /// Compatibility shim: `checkKubernetesAvailable()` with every error read as `false`.
    public func kubernetesAvailable() async -> Bool {
        (try? await checkKubernetesAvailable()) ?? false
    }

    /// Capabilities of the installed plugin, detected from `--help` and cached for as long as the `container`
    /// binary on disk stays the same (an upgrade replaces it, which triggers a fresh detection). A missing
    /// plugin (`nil`) and failures are never cached, so they are probed again on the next call.
    public func kubernetesCapabilities() async throws -> KubernetesCapabilities? {
        let fingerprint = Self.fingerprint(of: executable)
        if let cache = kubernetesCache, cache.fingerprint == fingerprint { return cache.capabilities }
        forgetKubernetesCapabilities()
        guard let detected = try await detectKubernetesCapabilities() else { return nil }
        kubernetesCache = (detected, fingerprint)
        return detected
    }

    /// Drops the cached capabilities and what was learned about cluster nodes; the next call detects again.
    public func forgetKubernetesCapabilities() {
        kubernetesCache = nil
        clusterNodes = ClusterNodeIndex()
    }

    /// Probes `cluster --help`, then `k8s --help`, and reads the subcommand help screens of the one that exists.
    func detectKubernetesCapabilities() async throws -> KubernetesCapabilities? {
        for word in KubernetesCapabilities.commandWords {
            let arguments = [word, "--help"]
            let result = try await runRaw(arguments, timeout: .seconds(15))
            if result.exitCode == 0 {
                return try await readCapabilities(word: word, pluginHelp: result.stdoutText)
            }
            let raw = result.stderrText + result.stdoutText
            if CLIErrorMapper.indicatesSystemNotRunning(raw) { throw BackendError.systemNotRunning }
            guard raw.localizedCaseInsensitiveContains("unknown command") || CLIErrorMapper.isPluginsUnavailable(raw)
            else { throw await failure(arguments, result) }
        }
        // No plugin under either name. Both messages are also printed when services are down; ask
        // `system status` to tell the two apart.
        let status = try? await runner.run(
            [executable, "system", "status"], stdin: nil, timeout: .seconds(15), environment: [:])
        if status?.exitCode == 0 { return nil }
        throw BackendError.systemNotRunning
    }

    /// `<word> create --help`, `<word> list --help` and, when the subcommand exists, `<word> load-image --help`.
    private func readCapabilities(word: String, pluginHelp: String) async throws -> KubernetesCapabilities {
        let createHelp = try await execute([word, "create", "--help"], timeout: .seconds(15)).stdoutText
        let listHelp = try await execute([word, "list", "--help"], timeout: .seconds(15)).stdoutText
        var loadImageHelp: String?
        if KubernetesCapabilities.subcommands(in: pluginHelp).contains("load-image") {
            loadImageHelp = try? await execute([word, "load-image", "--help"], timeout: .seconds(15)).stdoutText
        }
        return KubernetesCapabilities.detect(
            commandWord: word, pluginHelp: pluginHelp, createHelp: createHelp, listHelp: listHelp,
            loadImageHelp: loadImageHelp)
    }

    /// The detected capabilities, or `.unsupported` when the CLI has no Kubernetes plugin.
    func requireKubernetes() async throws -> KubernetesCapabilities {
        guard let capabilities = try await kubernetesCapabilities() else {
            throw BackendError.unsupported(
                feature: "Kubernetes", reason: "this container CLI has no `cluster` (or `k8s`) plugin.")
        }
        return capabilities
    }

    /// Runs a plugin command. A usage error (the plugin no longer knows the subcommand or option) means the
    /// cached capabilities are stale, so they are dropped before the error is rethrown.
    @discardableResult
    private func runPlugin(_ arguments: [String], timeout: Duration? = queryTimeout) async throws -> ProcessResult {
        do {
            return try await execute(arguments, timeout: timeout)
        } catch {
            if Self.isUsageError(error) { forgetKubernetesCapabilities() }
            throw error
        }
    }

    /// ArgumentParser's wording for an argv it cannot parse.
    static func isUsageError(_ error: any Error) -> Bool {
        guard case BackendError.commandFailed(_, _, let message) = error else { return false }
        return ["unknown command", "unknown option", "unexpected argument", "missing expected argument"]
            .contains { message.localizedCaseInsensitiveContains($0) }
    }

    /// Lists clusters.
    ///
    /// - JSON-capable plugin (1.7+): `cluster list --format json` for the cluster records, plus the
    ///   `cluster list --nodes` table for per-node CPU and memory, which the JSON does not carry.
    /// - Older plugin: `k8s ls` / `cluster ls` (per-node table), grouped into clusters.
    public func listClusters() async throws -> [KubernetesCluster] {
        let capabilities = try await requireKubernetes()
        let word = capabilities.commandWord
        guard capabilities.listsJSON else {
            let result = try await runPlugin([word, "ls"])
            let clusters = CLIOutputParsing.clusters(result.stdoutText)
            rememberClusterNodes(clusters)
            return clusters
        }
        let arguments = [word, "list", "--format", "json"]
        let resources = try decodeClusterList(try await runPlugin(arguments).stdout, arguments)
        var nodeTable: [KubernetesCluster] = []
        if capabilities.listsNodes, !resources.isEmpty {
            // Best effort: without the table the nodes simply show no CPU / memory figures.
            let table = try? await runPlugin([word, "list", "--nodes"])
            nodeTable = table.map { CLIOutputParsing.clusters($0.stdoutText) } ?? []
        }
        let clusters = resources.map { KubernetesCluster(resource: $0, nodeTable: nodeTable) }
        rememberClusterNodes(clusters)
        return clusters
    }

    /// Decodes `[ClusterResource]` leniently (an undecodable element is skipped); empty output is an empty list.
    private nonisolated func decodeClusterList(_ data: Data, _ arguments: [String]) throws -> [ClusterResource] {
        guard data.contains(where: { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }) else { return [] }
        do {
            let list = try CLIJSON.decode(LossyArray<ClusterResource>.self, from: data)
            if list.droppedCount > 0 {
                let command = display(arguments)
                Self.log.error(
                    "Skipped \(list.droppedCount, privacy: .public) undecodable cluster(s) from `\(command, privacy: .public)`"
                )
            }
            return list.elements
        } catch {
            throw BackendError.decoding(command: display(arguments), underlying: String(describing: error))
        }
    }

    /// `container <word> create --name N [-c N] [-m SIZE] [--node-image REF] [--cni FILE] [--rm] [--workers …]
    /// [--shared-image-store]`. Options the installed plugin lacks fail with `.unsupported` before anything runs.
    public nonisolated func createCluster(_ spec: ClusterSpec) -> LineStream {
        validatedStream {
            try Self.validateOperand(spec.name, "Cluster name")
            return deferredStream {
                let capabilities = try await self.requireKubernetes()
                return self.streamCommand(try spec.createArguments(for: capabilities))
            }
        }
    }

    /// `container <word> delete --name NAME`.
    public func deleteCluster(_ name: String) async throws {
        try Self.validateOperand(name, "Cluster name")
        let capabilities = try await requireKubernetes()
        try await runPlugin([capabilities.commandWord, "delete", "--name", name], timeout: .seconds(300))
    }

    /// `container <word> load-image [--name CLUSTER] [--platform P] [--node N]… -- REF`.
    ///
    /// Fails with `.unsupported` when the plugin has no `load-image` (1.7+, where clusters created with the
    /// shared image store read local images directly) or, for `nodes`, no `--node` option (1.5.0).
    public nonisolated func loadImage(
        _ reference: String, intoCluster cluster: String?, nodes: [String], platform: Platform?
    ) -> LineStream {
        validatedStream {
            try Self.validateOperand(reference, "Image reference")
            if let cluster { try Self.validateOperand(cluster, "Cluster name") }
            try Self.validateOperands(nodes, "Node name")
            return deferredStream {
                let capabilities = try await self.requireKubernetes()
                return self.streamCommand(
                    try Self.loadImageArguments(
                        reference, cluster: cluster, nodes: nodes, platform: platform, capabilities: capabilities))
            }
        }
    }

    /// argv after the executable for `loadImage`, or `.unsupported` when the plugin cannot do it.
    static func loadImageArguments(
        _ reference: String, cluster: String?, nodes: [String], platform: Platform?,
        capabilities: KubernetesCapabilities
    ) throws -> [String] {
        let command = "`\(capabilities.displayCommand)`"
        guard capabilities.supportsLoadImage else {
            throw BackendError.unsupported(
                feature: "Loading an image into a cluster",
                reason: "\(command) has no load-image command in this CLI version. Create the cluster with the "
                    + "shared image store and its nodes use your local images directly.")
        }
        guard nodes.isEmpty || capabilities.supportsLoadImageNodes else {
            throw BackendError.unsupported(
                feature: "Loading an image into specific nodes",
                reason: "\(command) load-image has no --node option in this CLI version.")
        }
        var arguments = [capabilities.commandWord, "load-image"]
        if let cluster { arguments += ["--name", cluster] }
        if let platform { arguments += ["--platform", platform.slug] }
        for node in nodes { arguments += ["--node", node] }
        arguments += ["--", reference]
        return arguments
    }

    /// A stream whose command line is only known after an `await` (here: capability detection). Errors thrown
    /// while preparing it finish the stream, like `validatedStream` does for synchronous checks.
    nonisolated func deferredStream(_ make: @escaping @Sendable () async throws -> LineStream) -> LineStream {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(ProcessRunner.streamBufferLimit)) { continuation in
            let task = Task {
                do {
                    for try await line in try await make() { continuation.yield(line) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: BackendError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Identifies the binary on disk (resolved path, modification time, size) without running it, so replacing
    /// the CLI while the app runs is noticed. A path that cannot be read yields a constant.
    static func fingerprint(of executable: String) -> String {
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return path }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        return "\(path)|\(modified)|\(size)"
    }
}
