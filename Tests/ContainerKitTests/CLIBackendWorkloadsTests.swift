import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

/// `CLIBackend`'s workloads calls: the exact argv of every `kubectl` it runs inside the control-plane node,
/// and how its failures are explained.
@Suite("CLIBackend workloads")
struct CLIBackendWorkloadsTests {
    let target = KubectlTarget(cluster: "dev", node: "dev")
    /// What precedes every kubectl argument.
    let prefix = ["exec", "--", "dev", "kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf"]

    private func make(
        streamLines: [OutputLine] = [], streamError: (any Error & Sendable)? = nil,
        _ handler: @escaping RecordingRunner.Handler = { _ in ProcessResult(stdout: "{}") }
    ) throws -> (CLIBackend, RecordingRunner) {
        let runner = RecordingRunner(streamLines: streamLines, streamError: streamError, handler: handler)
        return (try CLIBackend.recording(runner), runner)
    }

    @Test func listsEverythingInOneCall() async throws {
        let (backend, runner) = try make { _ in
            ProcessResult(stdout: FixtureSet.cli171.data("kubectl-workloads.json"))
        }
        let workloads = try await backend.clusterWorkloads(target)
        #expect(workloads.pods.count == 14 && workloads.deployments.count == 2 && workloads.services.count == 3)
        #expect(
            runner.commands == [
                prefix + ["get", "pods,deployments,services,nodes,namespaces", "--all-namespaces", "-o", "json"]
            ])
    }

    @Test func eventsAreAskedForOnePodAndSortedOldestFirst() async throws {
        let (backend, runner) = try make { _ in
            ProcessResult(stdout: FixtureSet.cli171.data("kubectl-pod-events.json"))
        }
        let events = try await backend.podEvents(target, namespace: "shop", pod: "worker")
        #expect(
            runner.commands == [
                prefix + [
                    "get", "events", "-n", "shop", "--field-selector",
                    "involvedObject.kind=Pod,involvedObject.name=worker", "-o", "json",
                ]
            ])
        let seen = events.compactMap(\.lastSeen)
        #expect(seen == seen.sorted() && seen.count == events.count)
    }

    @Test func actionsRunTheCommandsTheUIShows() async throws {
        let (backend, runner) = try make()
        try await backend.deletePod(target, namespace: "shop", name: "worker")
        try await backend.restartDeployment(target, namespace: "shop", name: "web")
        try await backend.scaleDeployment(target, namespace: "shop", name: "web", replicas: 3)
        #expect(
            runner.commands == [
                prefix + ["delete", "pod", "-n", "shop", "worker"],
                prefix + ["rollout", "restart", "-n", "shop", "deployment/web"],
                prefix + ["scale", "-n", "shop", "deployment/web", "--replicas=3"],
            ])
        // The copyable command is the argv that ran.
        #expect(
            KubectlAction.scaleDeployment(namespace: "shop", name: "web", replicas: 3).displayCommand(in: target)
                == "container " + runner.commands[2].joined(separator: " "))
        #expect(
            KubectlAction.deletePod(namespace: "my ns", name: "worker").displayCommand(in: target)
                == "container exec -- dev kubectl --kubeconfig /etc/kubernetes/admin.conf delete pod -n 'my ns' worker")
    }

    @Test func logsStreamWithTheChosenOptions() async throws {
        let (backend, runner) = try make(streamLines: [OutputLine("listening on :8080")])
        let plain = await drain(backend.podLogs(target, namespace: "shop", pod: "web-1", options: PodLogOptions()))
        #expect(plain.lines.map(\.text) == ["listening on :8080"] && plain.error == nil)
        _ = await drain(
            backend.podLogs(
                target, namespace: "shop", pod: "worker",
                options: PodLogOptions(container: "worker", follow: true, previous: true, tail: nil)))
        #expect(
            runner.commands == [
                prefix + ["logs", "-n", "shop", "web-1", "--tail=1000"],
                prefix + ["logs", "-n", "shop", "worker", "-c", "worker", "--follow", "--previous"],
            ])
        #expect(runner.calls.allSatisfy { $0.streamed })
    }

    @Test func namesThatLookLikeOptionsNeverReachTheCLI() async throws {
        let (backend, runner) = try make()
        await #expect(throws: BackendError.self) {
            try await backend.deletePod(target, namespace: "shop", name: "--all")
        }
        await #expect(throws: BackendError.self) {
            try await backend.deletePod(target, namespace: "-A", name: "worker")
        }
        await #expect(throws: BackendError.self) {
            try await backend.restartDeployment(target, namespace: "shop", name: "")
        }
        await #expect(throws: BackendError.self) {
            try await backend.scaleDeployment(target, namespace: "shop", name: "web", replicas: -1)
        }
        await #expect(throws: BackendError.self) {
            _ = try await backend.clusterWorkloads(KubectlTarget(cluster: "dev", node: "--rm"))
        }
        let logs = await drain(
            backend.podLogs(target, namespace: "shop", pod: "web", options: PodLogOptions(container: "-x")))
        #expect(logs.error is BackendError)
        #expect(runner.commands.isEmpty)
    }

    // MARK: Failures (stderr as recorded or seen on a 1.7.1 engine)

    private func failure(_ stderr: String) async throws -> BackendError {
        let (backend, _) = try make { _ in ProcessResult(exitCode: 1, stdout: "", stderr: stderr) }
        do {
            _ = try await backend.clusterWorkloads(target)
        } catch let error as BackendError {
            return error
        }
        throw BackendError.other("expected a failure")
    }

    @Test func aNodeImageWithoutKubectlIsUnsupportedNotACrash() async throws {
        let error = try await failure(
            """
            Error: failed to find target executable kubectl
            Error: failed to start process 7a679eff in container dev (cause: "internalError: "failed to find target executable kubectl"")
            """)
        guard case .unsupported(let feature, let reason) = error else {
            Issue.record("expected unsupported, got \(error)")
            return
        }
        #expect(feature.contains("dev") && reason.contains("no kubectl"))
    }

    @Test func aMissingControlPlaneIsUnsupported() async throws {
        let error = try await failure("Error: get failed: container dev not found")
        guard case .unsupported(_, let reason) = error else {
            Issue.record("expected unsupported, got \(error)")
            return
        }
        #expect(reason.contains("not running"))
    }

    @Test func kubectlsOwnErrorsKeepTheirTextAndCommand() async throws {
        let error = try await failure(FixtureSet.cli171.text("kubectl-not-found.txt"))
        guard case .commandFailed(let command, _, let message) = error else {
            Issue.record("expected commandFailed, got \(error)")
            return
        }
        #expect(message.contains("(NotFound)") && message.contains("cd-it-no-such-pod"))
        #expect(command.contains("exec -- dev kubectl --kubeconfig /etc/kubernetes/admin.conf get"))

        let refused = try await failure(
            "The connection to the server dev:6443 was refused - did you specify the right host or port?")
        #expect(refused.errorDescription?.contains("not answering yet") == true)
    }

    @Test func outputThatIsNotJSONIsADecodingError() async throws {
        let (backend, _) = try make { _ in ProcessResult(stdout: "No resources found") }
        await #expect {
            _ = try await backend.clusterWorkloads(target)
        } throws: { error in
            if case BackendError.decoding = error { return true }
            return false
        }
    }

    @Test func kubectlRunsOnlyInARunningControlPlane() {
        var cluster = KubernetesCluster(
            name: "dev",
            nodes: [
                .init(name: "dev-worker-1", role: "worker", state: .running, cpus: 2, memoryMB: 2048),
                .init(name: "dev", role: "control-plane", state: .running, cpus: 2, memoryMB: 2048),
            ])
        #expect(cluster.kubectlTarget == KubectlTarget(cluster: "dev", node: "dev"))
        cluster.nodes[1].state = .stopped
        #expect(cluster.kubectlTarget == nil, "a running worker is not enough")
        #expect(KubernetesCluster(name: "empty", nodes: []).kubectlTarget == nil)
    }
}
