import ContainerKit
import Foundation

/// What runs in the mock's clusters. Every cluster starts with the recorded `kubectl` output of a real one
/// (`cli-1.7.1/kubectl-workloads.json`: a `shop` namespace with a two-pod `web` deployment and its service, a
/// crash-looping `worker` pod and a `reports` pod whose image cannot be pulled, next to the system pods), with
/// the node names replaced by the mock cluster's and the timestamps moved so that the recording looks fresh.
enum MockWorkloads {
    /// Node names in the recording.
    static let recordedControlPlane = "cd-it-wl-dev"
    static let recordedWorker = "cd-it-wl-dev-worker-1"

    /// The recorded workloads as they would look in `cluster` at `now`.
    static func seed(for cluster: KubernetesCluster, now: Date = .now) -> ClusterWorkloads {
        let data = adapted(FixtureSet.cli171.data("kubectl-workloads.json"), to: cluster, now: now)
        guard var workloads = try? CLIJSON.decode(ClusterWorkloads.self, from: data) else { return ClusterWorkloads() }
        // A single-node cluster maps both recorded nodes onto its one node.
        var seen = Set<String>()
        workloads.nodes = workloads.nodes.filter { seen.insert($0.name).inserted }
        return workloads
    }

    /// The recorded events of the crash-looping pod, adapted the same way.
    static func recordedEvents(for cluster: KubernetesCluster, now: Date = .now) -> [KubeEvent] {
        let data = adapted(FixtureSet.cli171.data("kubectl-pod-events.json"), to: cluster, now: now)
        return (try? CLIJSON.decode(KubeList<KubeEvent>.self, from: data))?.items ?? []
    }

    /// Renames the recorded nodes to `cluster`'s and shifts every timestamp so the newest one is just before `now`.
    static func adapted(_ data: Data, to cluster: KubernetesCluster, now: Date) -> Data {
        let controlPlane = cluster.controlPlaneNode?.name ?? cluster.name
        let worker = cluster.workerNodes.first?.name ?? controlPlane
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: recordedWorker, with: "\u{1}")
        text = text.replacingOccurrences(of: recordedControlPlane, with: controlPlane)
        text = text.replacingOccurrences(of: "\u{1}", with: worker)
        return Data(shiftingTimestamps(in: text, now: now).utf8)
    }

    /// Moves every `2026-11-12T06:00:35Z` in `text` by the same amount, so the latest lands 20 s before `now`.
    static func shiftingTimestamps(in text: String, now: Date) -> String {
        let pattern = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/
        let stamps = text.matches(of: pattern).compactMap { CLIJSON.parseDate(String($0.output)) }
        guard let newest = stamps.max() else { return text }
        let shift = now.addingTimeInterval(-20).timeIntervalSince(newest)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return text.replacing(pattern) { match in
            guard let date = CLIJSON.parseDate(String(match.output)) else { return String(match.output) }
            return formatter.string(from: date.addingTimeInterval(shift))
        }
    }

    // MARK: Changes

    static func notFound(_ kind: String, _ name: String, command: String) -> BackendError {
        .commandFailed(
            command: command, exitCode: 1, message: "Error from server (NotFound): \(kind) \"\(name)\" not found")
    }

    /// `kubectl delete pod`: a deployment's pod comes back under a new name, a bare pod is gone.
    static func deletePod(
        _ workloads: inout ClusterWorkloads, namespace: String, name: String, command: String, now: Date = .now
    ) throws {
        guard let index = workloads.pods.firstIndex(where: { $0.namespace == namespace && $0.name == name }) else {
            throw notFound("pods", name, command: command)
        }
        let pod = workloads.pods.remove(at: index)
        guard let owner = workloads.deployments.first(where: { $0.selects(pod) }) else { return }
        workloads.pods.insert(freshPod(of: owner, like: pod, now: now), at: index)
    }

    /// `kubectl rollout restart`: every pod of the deployment is replaced.
    static func restart(
        _ workloads: inout ClusterWorkloads, namespace: String, name: String, command: String, now: Date = .now
    ) throws {
        guard let deployment = workloads.deployments.first(where: { $0.namespace == namespace && $0.name == name })
        else { throw notFound("deployments.apps", name, command: command) }
        let revision = suffix(10)
        for index in workloads.pods.indices where deployment.selects(workloads.pods[index]) {
            workloads.pods[index] = freshPod(of: deployment, like: workloads.pods[index], revision: revision, now: now)
        }
    }

    /// `kubectl scale --replicas`: pods are added or removed and the deployment's counts follow.
    static func scale(
        _ workloads: inout ClusterWorkloads, namespace: String, name: String, replicas: Int, command: String,
        now: Date = .now
    ) throws {
        guard
            let index = workloads.deployments.firstIndex(where: { $0.namespace == namespace && $0.name == name })
        else { throw notFound("deployments.apps", name, command: command) }
        let deployment = workloads.deployments[index]
        var pods = workloads.pods(of: deployment)
        while pods.count > replicas, let last = pods.popLast() { workloads.pods.removeAll { $0.id == last.id } }
        let template = pods.first
        while pods.count < replicas {
            let pod = freshPod(of: deployment, like: template, revision: template.flatMap(revision), now: now)
            pods.append(pod)
            workloads.pods.append(pod)
        }
        workloads.deployments[index].spec = .init(replicas: replicas, selector: deployment.spec?.selector)
        workloads.deployments[index].status = .init(
            replicas: replicas, readyReplicas: replicas, updatedReplicas: replicas, availableReplicas: replicas)
    }

    /// A running, ready pod of `deployment`, named `<deployment>-<revision>-<5 characters>`.
    static func freshPod(
        of deployment: KubeDeployment, like template: KubePod?, revision: String? = nil, now: Date
    ) -> KubePod {
        let revision = revision ?? template.flatMap(self.revision) ?? suffix(10)
        let name = "\(deployment.name)-\(revision)-\(suffix(5))"
        let containers = template?.spec?.containers ?? [.init(name: deployment.name, image: "alpine:3.22")]
        var metadata = template?.metadata ?? KubeMetadata(name: name, namespace: deployment.namespace)
        metadata.name = name
        metadata.uid = UUID().uuidString.lowercased()
        metadata.creationTimestamp = now
        metadata.deletionTimestamp = nil
        metadata.labels = metadata.labels ?? deployment.spec?.selector?.matchLabels
        metadata.ownerReferences = [.init(kind: "ReplicaSet", name: "\(deployment.name)-\(revision)")]
        let statuses = containers.map {
            KubePod.ContainerStatus(
                name: $0.name, image: $0.image, ready: true, restartCount: 0, started: true,
                state: .init(running: .init(startedAt: now)), lastState: .init())
        }
        return KubePod(
            metadata: metadata,
            spec: .init(nodeName: template?.spec?.nodeName, containers: containers),
            status: .init(
                phase: .running, podIP: template?.status?.podIP, hostIP: template?.status?.hostIP, startTime: now,
                conditions: [.init(type: "Ready", status: "True")], containerStatuses: statuses))
    }

    /// The ReplicaSet hash in a deployment pod's name (`web-6dd7bbb5cf-67q2p` → `6dd7bbb5cf`).
    static func revision(of pod: KubePod) -> String? {
        let parts = pod.name.split(separator: "-")
        return parts.count >= 3 ? String(parts[parts.count - 2]) : nil
    }

    private static func suffix(_ length: Int) -> String {
        String((0..<length).compactMap { _ in "bcdfghjklmnpqrstvwxz2456789".randomElement() })
    }

    // MARK: Logs and events

    /// What `kubectl logs` prints for `pod`, or the error it fails with while the container cannot start.
    static func logLines(for pod: KubePod, options: PodLogOptions, command: String) throws -> [OutputLine] {
        let container = options.container ?? pod.spec?.containers?.first?.name ?? pod.name
        let status = pod.containerStatuses.first { $0.name == container }
        if let reason = status?.state?.waiting?.reason, reason.contains("ImagePull") || reason == "ContainerCreating" {
            throw BackendError.commandFailed(
                command: command, exitCode: 1,
                message: "Error from server (BadRequest): container \"\(container)\" in pod \"\(pod.name)\" is "
                    + "waiting to start: image can't be pulled")
        }
        if options.previous, status?.hasPreviousInstance != true {
            throw BackendError.commandFailed(
                command: command, exitCode: 1,
                message: "Error from server (BadRequest): previous terminated container \"\(container)\" in pod "
                    + "\"\(pod.name)\" not found")
        }
        if pod.health == .failing || options.previous {
            return [
                OutputLine("starting \(container)"),
                OutputLine("fatal: QUEUE_URL is not set", stream: .stderr),
            ]
        }
        let requests = (0..<min(options.tail ?? 40, 40)).map { _ in OutputLine("GET /healthz 200") }
        return [OutputLine("listening on :8080")] + requests
    }

    /// Events a healthy or image-less pod would have; the crash-looping one uses the recording.
    static func events(for pod: KubePod, in cluster: KubernetesCluster, now: Date = .now) -> [KubeEvent] {
        if pod.statusText == "CrashLoopBackOff" || pod.restartCount > 0 {
            return recordedEvents(for: cluster, now: now)
        }
        let created = pod.metadata.creationTimestamp ?? now
        let image = pod.spec?.containers?.first?.image ?? "image"
        let container = pod.spec?.containers?.first?.name ?? pod.name
        var steps: [(type: String, reason: String, message: String, component: String)] = [
            ("Normal", "Scheduled", "Successfully assigned \(pod.id) to \(pod.nodeName ?? "node")", "default-scheduler")
        ]
        if pod.statusText.contains("ImagePull") {
            steps += [
                ("Normal", "Pulling", "Pulling image \"\(image)\"", "kubelet"),
                ("Warning", "Failed", "Failed to pull image \"\(image)\": failed to resolve reference", "kubelet"),
                ("Warning", "Failed", "Error: ErrImagePull", "kubelet"),
                ("Normal", "BackOff", "Back-off pulling image \"\(image)\"", "kubelet"),
            ]
        } else {
            steps += [
                ("Normal", "Pulled", "Container image \"\(image)\" already present on machine", "kubelet"),
                ("Normal", "Created", "Container created", "kubelet"),
                ("Normal", "Started", "Container \(container) started", "kubelet"),
            ]
        }
        return steps.enumerated().map { index, step in
            KubeEvent(
                metadata: KubeMetadata(
                    name: "\(pod.name).\(index)", namespace: pod.namespace, uid: "\(pod.id)#\(index)"),
                type: step.type, reason: step.reason, message: step.message, count: 1, firstTimestamp: created,
                lastTimestamp: created.addingTimeInterval(Double(index)), source: .init(component: step.component))
        }
    }
}
