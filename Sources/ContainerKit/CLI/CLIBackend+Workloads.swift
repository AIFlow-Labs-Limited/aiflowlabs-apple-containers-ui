import Foundation

// MARK: - KubernetesWorkloadOperations

// Every call here is `container exec -- <control-plane node> kubectl --kubeconfig /etc/kubernetes/admin.conf …`
// (see `Kubectl.swift` for why). Nothing is cached, and the kubeconfig is only ever named, never read.
extension CLIBackend {
    /// Timeout for a `kubectl` that changes something (`delete pod` waits for the pod to go away).
    static let kubectlActionTimeout: Duration = .seconds(120)

    public func clusterWorkloads(_ target: KubectlTarget) async throws -> ClusterWorkloads {
        try await decodeKubectl(ClusterWorkloads.self, .workloads, in: target)
    }

    public func podEvents(_ target: KubectlTarget, namespace: String, pod: String) async throws -> [KubeEvent] {
        let list = try await decodeKubectl(
            KubeList<KubeEvent>.self, .podEvents(namespace: namespace, pod: pod), in: target)
        return list.items.sorted { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }
    }

    public nonisolated func podLogs(
        _ target: KubectlTarget, namespace: String, pod: String, options: PodLogOptions
    ) -> LineStream {
        let action = KubectlAction.logs(namespace: namespace, pod: pod, options: options)
        return validatedStream {
            try Self.validate(action, in: target)
            let arguments = action.execArguments(in: target)
            let upstream = streamCommand(arguments)
            let command = display(arguments)
            // `streamCommand` reports a failure as the generic CLI error; say what kubectl said instead.
            return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(ProcessRunner.streamBufferLimit)) {
                continuation in
                let task = Task {
                    do {
                        for try await line in upstream { continuation.yield(line) }
                        continuation.finish()
                    } catch let error as BackendError {
                        continuation.finish(throwing: Self.kubectlError(error, target: target, command: command))
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    public func deletePod(_ target: KubectlTarget, namespace: String, name: String) async throws {
        try await runKubectl(
            .deletePod(namespace: namespace, name: name), in: target, timeout: Self.kubectlActionTimeout)
    }

    public func restartDeployment(_ target: KubectlTarget, namespace: String, name: String) async throws {
        try await runKubectl(
            .restartDeployment(namespace: namespace, name: name), in: target, timeout: Self.kubectlActionTimeout)
    }

    public func scaleDeployment(
        _ target: KubectlTarget, namespace: String, name: String, replicas: Int
    ) async throws {
        guard replicas >= 0 else { throw BackendError.other("A deployment cannot have fewer than 0 replicas.") }
        try await runKubectl(
            .scaleDeployment(namespace: namespace, name: name, replicas: replicas), in: target,
            timeout: Self.kubectlActionTimeout)
    }

    // MARK: Helpers

    /// Runs `action` in the control-plane node; a failure is explained by `kubectlError`.
    @discardableResult
    nonisolated func runKubectl(
        _ action: KubectlAction, in target: KubectlTarget, timeout: Duration? = queryTimeout
    ) async throws -> ProcessResult {
        try Self.validate(action, in: target)
        let arguments = action.execArguments(in: target)
        do {
            return try await execute(arguments, timeout: timeout)
        } catch let error as BackendError {
            throw Self.kubectlError(error, target: target, command: display(arguments))
        }
    }

    /// Runs a JSON-producing `action` and decodes its output.
    private nonisolated func decodeKubectl<T: Decodable>(
        _ type: T.Type, _ action: KubectlAction, in target: KubectlTarget
    ) async throws -> T {
        let result = try await runKubectl(action, in: target)
        do {
            return try CLIJSON.decode(type, from: result.stdout)
        } catch {
            throw BackendError.decoding(
                command: display(action.execArguments(in: target)), underlying: String(describing: error))
        }
    }

    /// Rejects an empty name and one the CLI or kubectl would read as an option.
    static func validate(_ action: KubectlAction, in target: KubectlTarget) throws {
        try validateOperand(target.node, "Cluster node")
        guard !target.node.isEmpty else { throw BackendError.other("The cluster has no control-plane node.") }
        for operand in action.operands {
            guard !operand.value.isEmpty else { throw BackendError.other("\(operand.what) is empty.") }
            try validateOperand(operand.value, operand.what)
        }
    }

    /// Turns the CLI's wording for the ways `container exec … kubectl` fails into something a person can act
    /// on. Errors from the API server (`Error from server (NotFound): …`) pass through with kubectl's text.
    static func kubectlError(_ error: BackendError, target: KubectlTarget, command: String) -> BackendError {
        let text: String
        switch error {
        case .commandFailed(_, _, let message): text = message
        case .notFound(_, let id) where id == target.node:
            return .unsupported(
                feature: "Workloads of “\(target.cluster)”",
                reason: "its control-plane node “\(target.node)” is not running.")
        case .notFound(let kind, let id):
            // The mapper reads kubectl's `pods "x" not found` as a missing container resource; keep the command.
            return .commandFailed(command: command, exitCode: 1, message: "\(kind.capitalized) “\(id)” was not found.")
        default: return error
        }
        if text.localizedCaseInsensitiveContains("failed to find target executable") {
            return .unsupported(
                feature: "Workloads of “\(target.cluster)”",
                reason: "the node image of this cluster has no kubectl, which Container Desktop runs inside the "
                    + "control-plane node. Use kubectl on this Mac with the cluster's context instead.")
        }
        if text.localizedCaseInsensitiveContains("container \(target.node) not found")
            || text.localizedCaseInsensitiveContains("is not running")
        {
            return .unsupported(
                feature: "Workloads of “\(target.cluster)”",
                reason: "its control-plane node “\(target.node)” is not running.")
        }
        if text.localizedCaseInsensitiveContains("connection to the server")
            || text.localizedCaseInsensitiveContains("connection refused")
        {
            return .commandFailed(
                command: command, exitCode: 1,
                message: "The cluster's API server is not answering yet. It takes a moment after the cluster starts. "
                    + "(\(text))")
        }
        return error
    }
}
