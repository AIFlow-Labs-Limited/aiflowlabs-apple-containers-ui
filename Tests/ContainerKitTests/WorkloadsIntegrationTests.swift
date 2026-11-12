import Foundation
import Testing

@testable import ContainerKit

/// The workloads calls against a real cluster: one single-node cluster named `cd-it-wl-…` gets a small
/// deployment and a service, which are then listed, logged, scaled, restarted and deleted through the backend,
/// exactly as the app does it (`kubectl` inside the control-plane node). The cluster is deleted in a cleanup
/// path that also runs on failure. The node image (`kindest/node`) and `alpine:3.22` must be local.
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@Suite("Workloads Integration", .serialized, .enabled(if: Integration.isEnabled, Integration.hint))
struct WorkloadsIntegrationTests {
    let backend: CLIBackend
    static let image = "alpine:3.22"

    init() throws {
        backend = try CLIBackend()
    }

    @Test(.timeLimit(.minutes(20)))
    func listsLogsScalesRestartsAndDeletes() async throws {
        let capabilities = try #require(try await backend.kubernetesCapabilities())
        let name = Integration.uniqueName("wl")
        var spec = ClusterSpec(name: name)
        spec.cpus = 2
        spec.memory = MemorySize(bytes: 2 << 30)
        spec.sharedImageStore = capabilities.supportsSharedImageStore
        do {
            for try await _ in backend.createCluster(spec) {}
            let cluster = try #require(try await backend.listClusters().first { $0.name == name })
            let target = try #require(cluster.kubectlTarget)
            #expect(target == KubectlTarget(cluster: name, node: name))
            try await exercise(target)
            try await backend.deleteCluster(name)
        } catch {
            try? await backend.deleteCluster(name)
            throw error
        }
        #expect(try await !backend.listClusters().contains { $0.name == name })
    }

    private func exercise(_ target: KubectlTarget) async throws {
        // A fresh cluster: system pods only, the `default` namespace is empty.
        let fresh = try await waitFor("the system pods", in: target) { workloads in
            workloads.pods.count >= 5 && workloads.pods.allSatisfy { $0.health == .healthy }
        }
        #expect(fresh.droppedCount == 0)
        #expect(fresh.pods.allSatisfy { $0.namespace == "kube-system" || $0.namespace == "local-path-storage" })
        #expect(fresh.nodes.map(\.name) == [target.node] && fresh.nodes[0].isReady)
        #expect(fresh.nodes[0].roles.contains("control-plane"))
        #expect(fresh.namespaces.contains { $0.name == "default" })
        #expect(fresh.services.contains { $0.id == "default/kubernetes" && $0.portsText == "443/TCP" })
        #expect(fresh.deployments.contains { $0.id == "kube-system/coredns" })

        // A deployment and a service, made with the node's own kubectl (the app has no "apply" yet).
        try await kubectl(
            target,
            [
                "create", "deployment", "web", "--image=\(Self.image)", "--replicas=2", "--", "sh", "-c",
                "echo listening-on-8080; while true; do sleep 5; done",
            ])
        try await kubectl(target, ["create", "service", "clusterip", "web", "--tcp=80:8080"])

        let deployed = try await waitFor("two ready web pods", in: target) { workloads in
            workloads.deployments.first { $0.id == "default/web" }?.isSettled == true
        }
        let web = try #require(deployed.deployments.first { $0.id == "default/web" })
        #expect(web.readyText == "2/2" && web.updatedReplicas == 2 && web.availableReplicas == 2)
        let pods = deployed.pods(of: web)
        #expect(pods.count == 2)
        for pod in pods {
            #expect(pod.statusText == "Running" && pod.readyText == "1/1" && pod.restartCount == 0)
            #expect(pod.nodeName == target.node && pod.ownerName?.hasPrefix("web-") == true)
        }
        let service = try #require(deployed.services.first { $0.id == "default/web" })
        #expect(service.type == "ClusterIP" && service.portsText == "80/TCP")
        #expect(service.spec?.clusterIP?.isEmpty == false)

        // Logs: the whole log, then a followed stream that is cancelled.
        let pod = try #require(pods.first)
        let logs = await drain(
            backend.podLogs(target, namespace: "default", pod: pod.name, options: PodLogOptions(container: "alpine")))
        #expect(logs.error == nil, "\(String(describing: logs.error))")
        #expect(logs.lines.map(\.text) == ["listening-on-8080"])
        var followed: [String] = []
        for try await line in backend.podLogs(
            target, namespace: "default", pod: pod.name, options: PodLogOptions(follow: true))
        {
            followed.append(line.text)
            break  // leaving the loop cancels `kubectl logs --follow`
        }
        #expect(followed == ["listening-on-8080"])
        let previous = await Integration.backendError {
            for try await _ in backend.podLogs(
                target, namespace: "default", pod: pod.name, options: PodLogOptions(previous: true))
            {}
        }
        #expect(previous != nil, "a container that never restarted has no previous log")

        // Events of the pod: scheduled, pulled, created, started.
        let events = try await backend.podEvents(target, namespace: "default", pod: pod.name)
        #expect(events.contains { $0.reason == "Scheduled" })
        #expect(events.contains { $0.reason == "Started" })
        #expect(events.allSatisfy { !$0.isWarning })

        // Scale up.
        try await backend.scaleDeployment(target, namespace: "default", name: "web", replicas: 3)
        let scaled = try await waitFor("three ready web pods", in: target) { workloads in
            workloads.deployments.first { $0.id == "default/web" }?.readyText == "3/3"
        }
        #expect(scaled.pods.count { $0.name.hasPrefix("web-") && $0.health == .healthy } == 3)

        // Rollout restart: every pod is replaced by one of a new ReplicaSet.
        let before = Set(scaled.pods.filter { $0.name.hasPrefix("web-") }.map(\.name))
        try await backend.restartDeployment(target, namespace: "default", name: "web")
        let restarted = try await waitFor("the restarted pods", in: target) { workloads in
            let current = workloads.pods.filter { $0.name.hasPrefix("web-") }
            return current.count == 3 && before.isDisjoint(with: current.map(\.name))
                && current.allSatisfy { $0.health == .healthy }
        }
        #expect(restarted.deployments.first { $0.id == "default/web" }?.isSettled == true)

        // Delete one pod: the deployment starts a replacement.
        let victim = try #require(restarted.pods.first { $0.name.hasPrefix("web-") })
        try await backend.deletePod(target, namespace: "default", name: victim.name)
        let replaced = try await waitFor("a replacement pod", in: target) { workloads in
            let current = workloads.pods.filter { $0.name.hasPrefix("web-") }
            return current.count == 3 && !current.contains { $0.name == victim.name }
                && current.allSatisfy { $0.health == .healthy }
        }
        #expect(replaced.pods.count { $0.name.hasPrefix("web-") } == 3)

        // Errors keep kubectl's words and the command.
        let missing = await Integration.backendError {
            try await backend.deletePod(target, namespace: "default", name: victim.name)
        }
        guard case .commandFailed(let command, _, let message) = missing else {
            Issue.record("expected commandFailed, got \(String(describing: missing))")
            return
        }
        #expect(message.contains("NotFound") && message.contains(victim.name))
        #expect(command.contains("kubectl --kubeconfig /etc/kubernetes/admin.conf delete pod -n default"))
    }

    /// Polls the cluster (every 2 s, up to 4 minutes) until `condition` holds, and returns that snapshot.
    private func waitFor(
        _ what: String, in target: KubectlTarget, _ condition: (ClusterWorkloads) -> Bool
    ) async throws -> ClusterWorkloads {
        var last: ClusterWorkloads?
        var lastError: (any Error)?
        for _ in 0..<120 {
            do {
                let workloads = try await backend.clusterWorkloads(target)
                if condition(workloads) { return workloads }
                last = workloads
            } catch {
                lastError = error  // the API server may need a moment right after `create`
            }
            try await Task.sleep(for: .seconds(2))
        }
        let pods = last?.pods.map { "\($0.id)=\($0.statusText)" }.joined(separator: ", ") ?? "no snapshot"
        Issue.record("timed out waiting for \(what): \(pods); last error: \(String(describing: lastError))")
        throw BackendError.other("timed out waiting for \(what)")
    }

    private func kubectl(_ target: KubectlTarget, _ arguments: [String]) async throws {
        let result = try await backend.execCapture(
            target.node, command: ["kubectl", "--kubeconfig", KubectlAction.kubeconfigPath] + arguments,
            workingDirectory: nil)
        try #require(result.exitCode == 0, "kubectl \(arguments.joined(separator: " ")): \(result.stderr)")
    }
}
