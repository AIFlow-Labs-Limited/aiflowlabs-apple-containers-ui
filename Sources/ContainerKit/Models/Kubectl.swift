import Foundation

// How the app talks to a cluster's API server: it runs the `kubectl` that ships in the node image, inside the
// control-plane node, with the admin kubeconfig that kubeadm wrote there:
//
//     container exec -- <control-plane node> kubectl --kubeconfig /etc/kubernetes/admin.conf <arguments>
//
// The Mac needs no kubectl, no `~/.kube/config` and no DNS domain for that (the kubeconfig on the Mac points
// at `https://<cluster>.<domain>:6443`, which only resolves once a domain is registered with administrator
// rights). The kubeconfig never leaves the node: only its path is passed.

/// Where `kubectl` runs for a cluster: its control-plane node's container.
public struct KubectlTarget: Hashable, Sendable {
    /// The cluster's name (for messages).
    public var cluster: String
    /// The control-plane node's container name.
    public var node: String

    public init(cluster: String, node: String) {
        self.cluster = cluster; self.node = node
    }
}

extension KubernetesCluster {
    /// Where to run `kubectl` for this cluster; `nil` while its control-plane node is not running.
    public var kubectlTarget: KubectlTarget? {
        guard let node = controlPlaneNode, node.state == .running else { return nil }
        return KubectlTarget(cluster: name, node: node.name)
    }
}

/// What to read from a pod's log.
public struct PodLogOptions: Hashable, Sendable {
    /// The container to read; `nil` lets kubectl pick the pod's default container.
    public var container: String?
    /// Keep the stream open for new lines.
    public var follow: Bool
    /// Read the previous instance of the container (the one that crashed) instead of the current one.
    public var previous: Bool
    /// Only the last `tail` lines; `nil` for the whole log.
    public var tail: Int?

    public init(container: String? = nil, follow: Bool = false, previous: Bool = false, tail: Int? = 1000) {
        self.container = container; self.follow = follow; self.previous = previous; self.tail = tail
    }
}

/// One `kubectl` invocation the app makes. `arguments` is what follows `kubectl --kubeconfig …`; the same
/// value builds the command that runs and the command that is shown, so the two cannot drift apart.
public enum KubectlAction: Hashable, Sendable {
    /// Everything the workloads view lists, in one call.
    case workloads
    case podEvents(namespace: String, pod: String)
    case logs(namespace: String, pod: String, options: PodLogOptions)
    case deletePod(namespace: String, name: String)
    case restartDeployment(namespace: String, name: String)
    case scaleDeployment(namespace: String, name: String, replicas: Int)

    /// The kinds `workloads` asks for.
    public static let workloadKinds = "pods,deployments,services,nodes,namespaces"
    /// Where kubeadm leaves the cluster-admin kubeconfig in a control-plane node.
    public static let kubeconfigPath = "/etc/kubernetes/admin.conf"

    /// Arguments after `kubectl --kubeconfig <path>`.
    public var arguments: [String] {
        switch self {
        case .workloads:
            return ["get", Self.workloadKinds, "--all-namespaces", "-o", "json"]
        case .podEvents(let namespace, let pod):
            return [
                "get", "events", "-n", namespace, "--field-selector",
                "involvedObject.kind=Pod,involvedObject.name=\(pod)", "-o", "json",
            ]
        case .logs(let namespace, let pod, let options):
            var arguments = ["logs", "-n", namespace, pod]
            if let container = options.container { arguments += ["-c", container] }
            if options.follow { arguments.append("--follow") }
            if options.previous { arguments.append("--previous") }
            if let tail = options.tail { arguments.append("--tail=\(tail)") }
            return arguments
        case .deletePod(let namespace, let name):
            return ["delete", "pod", "-n", namespace, name]
        case .restartDeployment(let namespace, let name):
            return ["rollout", "restart", "-n", namespace, "deployment/\(name)"]
        case .scaleDeployment(let namespace, let name, let replicas):
            return ["scale", "-n", namespace, "deployment/\(name)", "--replicas=\(replicas)"]
        }
    }

    /// Arguments after `container` that run this action in `target`'s control-plane node.
    public func execArguments(in target: KubectlTarget) -> [String] {
        ["exec", "--", target.node, "kubectl", "--kubeconfig", Self.kubeconfigPath] + arguments
    }

    /// The command the app runs, shell-quoted, for "Copy Command" and confirmations.
    public func displayCommand(in target: KubectlTarget, executable: String = "container") -> String {
        ShellQuote.join([executable] + execArguments(in: target))
    }

    /// Names in the action that would be read as options if they started with `-`, with what they are.
    var operands: [(value: String, what: String)] {
        switch self {
        case .workloads: return []
        case .podEvents(let namespace, let pod):
            return [(namespace, "Namespace"), (pod, "Pod name")]
        case .logs(let namespace, let pod, let options):
            let container = options.container.map { [(value: $0, what: "Container name")] } ?? []
            return [(namespace, "Namespace"), (pod, "Pod name")] + container
        case .deletePod(let namespace, let name):
            return [(namespace, "Namespace"), (name, "Pod name")]
        case .restartDeployment(let namespace, let name), .scaleDeployment(let namespace, let name, _):
            return [(namespace, "Namespace"), (name, "Deployment name")]
        }
    }
}
