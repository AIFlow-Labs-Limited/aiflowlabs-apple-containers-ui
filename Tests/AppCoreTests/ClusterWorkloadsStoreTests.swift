import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

/// `ClusterWorkloadsStore` against `MockBackend`, whose clusters carry the recorded `shop` sample: a two-pod
/// `web` deployment with a service, a crash-looping `worker` pod and a `reports` pod without an image.
@MainActor
@Suite struct ClusterWorkloadsStoreTests {
    private func make() async throws -> (ClusterWorkloadsStore, MockBackend, KubernetesCluster) {
        let backend = MockBackend(kubernetes: .modern)
        await backend.setLatency(.zero)
        let cluster = try #require(try await backend.listClusters().first { $0.kubectlTarget != nil })
        let store = ClusterWorkloadsStore(backend: backend, gate: PollingGate(engineRunning: true))
        await store.show(cluster)?.value
        return (store, backend, cluster)
    }

    @Test func showsTheUsersWorkloadsAndHidesSystemOnesByDefault() async throws {
        let (store, _, cluster) = try await make()
        #expect(store.unavailableReason == nil && store.lastError == nil)
        #expect(store.target == KubectlTarget(cluster: cluster.name, node: cluster.controlPlaneNode?.name ?? ""))
        #expect(store.pods.map(\.namespace).allSatisfy { $0 == "shop" })
        #expect(store.pods.count == 4)
        #expect(store.deployments.map(\.id) == ["shop/web"])
        #expect(store.services.map(\.id) == ["default/kubernetes", "shop/web"])
        #expect(store.namespaceChoices == ["default", "shop"])
        #expect(store.hiddenSystemPodCount == 10)
        #expect(store.count(of: .pods) == 4 && store.count(of: .nodes) == store.nodes.count)
        #expect(store.troubleSummary == "2 pods are failing")
        // The recorded node names were replaced by this cluster's.
        let nodeNames = Set(cluster.nodes.map(\.name))
        #expect(store.nodes.allSatisfy { nodeNames.contains($0.name) })
        #expect(store.pods.compactMap(\.nodeName).allSatisfy(nodeNames.contains))
        // And the recording looks fresh: nothing is older than a day or in the future.
        for pod in store.pods {
            let age = Date.now.timeIntervalSince(try #require(pod.metadata.creationTimestamp))
            #expect(age > 0 && age < 86_400, "\(pod.name) is \(age)s old")
        }
    }

    @Test func namespacePickerAndSystemToggle() async throws {
        let (store, _, _) = try await make()
        store.showSystemNamespaces = true
        #expect(store.pods.count == 14)
        #expect(store.deployments.map(\.id) == ["kube-system/coredns", "shop/web"])
        #expect(store.namespaceChoices == ["default", "shop", "kube-node-lease", "kube-public", "kube-system"])
        #expect(store.hiddenSystemPodCount == 0)

        store.namespaceFilter = .named("kube-system")
        #expect(store.pods.count == 10 && store.pods.allSatisfy { $0.namespace == "kube-system" })
        #expect(store.services.map(\.name) == ["kube-dns"])

        store.namespaceFilter = .named("shop")
        store.searchText = "web"
        #expect(store.pods.count == 2 && store.pods.allSatisfy { $0.name.hasPrefix("web-") })
        store.searchText = ""

        // A namespace that disappears falls back to "all".
        store.namespaceFilter = .named("gone")
        await store.refresh()
        #expect(store.namespaceFilter == .all)
    }

    @Test func deletingADeploymentsPodBringsAReplacement() async throws {
        let (store, _, _) = try await make()
        let before = store.pods.filter { $0.name.hasPrefix("web-") }
        let victim = try #require(before.first)
        #expect(await store.deletePod(victim))
        let after = store.pods.filter { $0.name.hasPrefix("web-") }
        #expect(after.count == 2 && !after.contains { $0.name == victim.name })
        #expect(store.pod(id: victim.id) == nil)

        // A bare pod stays gone.
        let worker = try #require(store.pods.first { $0.name == "worker" })
        #expect(await store.deletePod(worker))
        #expect(!store.pods.contains { $0.name == "worker" })
        #expect(store.actionError == nil)

        // Deleting it again is the API server's NotFound, kept with the command that failed.
        #expect(await !store.deletePod(worker))
        guard case .commandFailed(let command, _, let message) = store.actionError else {
            Issue.record("expected commandFailed, got \(String(describing: store.actionError))")
            return
        }
        #expect(message.contains("(NotFound)"))
        #expect(command == store.command(for: .deletePod(namespace: "shop", name: "worker")))
    }

    @Test func scaleAndRestart() async throws {
        let (store, _, _) = try await make()
        let web = try #require(store.deployments.first)
        #expect(await store.scale(web, to: 4))
        #expect(store.deployments.first?.readyText == "4/4")
        #expect(store.pods.count { $0.name.hasPrefix("web-") } == 4)

        let names = Set(store.pods.filter { $0.name.hasPrefix("web-") }.map(\.name))
        #expect(await store.restart(try #require(store.deployments.first)))
        let restarted = store.pods.filter { $0.name.hasPrefix("web-") }
        #expect(restarted.count == 4 && names.isDisjoint(with: restarted.map(\.name)))
        #expect(restarted.allSatisfy { $0.health == .healthy })

        #expect(await store.scale(try #require(store.deployments.first), to: 0))
        #expect(store.deployments.first?.readyText == "0/0")
        #expect(!store.pods.contains { $0.name.hasPrefix("web-") })
        #expect(await store.scale(try #require(store.deployments.first), to: 1))
        #expect(store.pods.count { $0.name.hasPrefix("web-") } == 1)
    }

    @Test func commandsAreTheOnesTheBackendRuns() async throws {
        let (store, _, cluster) = try await make()
        let node = try #require(cluster.controlPlaneNode?.name)
        let kubectl = "container exec -- \(node) kubectl --kubeconfig /etc/kubernetes/admin.conf"
        #expect(
            store.command(for: .deletePod(namespace: "shop", name: "worker")) == "\(kubectl) delete pod -n shop worker")
        #expect(
            store.command(for: .restartDeployment(namespace: "shop", name: "web"))
                == "\(kubectl) rollout restart -n shop deployment/web")
        #expect(
            store.command(for: .scaleDeployment(namespace: "shop", name: "web", replicas: 3))
                == "\(kubectl) scale -n shop deployment/web --replicas=3")
        #expect(
            store.command(
                for: .logs(
                    namespace: "shop", pod: "worker",
                    options: PodLogOptions(container: "worker", follow: true, previous: true, tail: nil)))
                == "\(kubectl) logs -n shop worker -c worker --follow --previous")
    }

    @Test func eventsAndLogs() async throws {
        let (store, _, _) = try await make()
        let worker = try #require(store.pods.first { $0.name == "worker" })
        let events = try await store.events(for: worker)
        #expect(events.contains { $0.reason == "BackOff" && $0.isWarning })

        var lines: [OutputLine] = []
        for try await line in store.logs(for: worker, options: PodLogOptions(previous: true)) { lines.append(line) }
        #expect(lines.map(\.text) == ["starting worker", "fatal: QUEUE_URL is not set"])

        let web = try #require(store.pods.first { $0.name.hasPrefix("web-") })
        lines = []
        for try await line in store.logs(for: web, options: PodLogOptions(tail: 3)) { lines.append(line) }
        #expect(lines.first?.text == "listening on :8080" && lines.count == 4)
        #expect(try await store.events(for: web).map(\.reason) == ["Scheduled", "Pulled", "Created", "Started"])

        // A container that never started has no log: kubectl's error, not an empty view.
        let reports = try #require(store.pods.first { $0.name == "reports" })
        await #expect(throws: BackendError.self) {
            for try await _ in store.logs(for: reports, options: PodLogOptions()) {}
        }
        #expect(try await store.events(for: reports).contains { $0.reason == "Failed" && $0.isWarning })
    }

    @Test func aClusterWithoutARunningControlPlaneIsUnavailableNotAnError() async throws {
        let backend = MockBackend(kubernetes: .modern)
        await backend.setLatency(.zero)
        let clusters = try await backend.listClusters()
        let stopped = try #require(clusters.first { $0.kubectlTarget == nil })
        let store = ClusterWorkloadsStore(backend: backend, gate: PollingGate(engineRunning: true))
        #expect(store.unavailableReason != nil, "nothing selected")

        await store.show(stopped)?.value
        #expect(store.workloads == nil && store.lastError == nil)
        #expect(store.unavailableReason?.contains(stopped.name) == true)
        #expect(store.command(for: .workloads) == nil)
        #expect(store.pods.isEmpty && store.count(of: .deployments) == 0)

        // Actions explain themselves instead of running anything.
        let pod = KubePod(metadata: KubeMetadata(name: "x", namespace: "default"))
        #expect(await !store.deletePod(pod))
        guard case .unsupported = store.actionError else {
            Issue.record("expected unsupported, got \(String(describing: store.actionError))")
            return
        }
        await #expect(throws: BackendError.self) {
            for try await _ in store.logs(for: pod, options: PodLogOptions()) {}
        }
    }

    @Test func switchingClustersDropsTheOldSnapshot() async throws {
        let (store, backend, cluster) = try await make()
        #expect(store.workloads != nil)
        store.namespaceFilter = .named("shop")
        let other = KubernetesCluster(
            name: "other",
            nodes: [.init(name: "other", role: "control-plane,worker", state: .running, cpus: 2, memoryMB: 2048)])
        await backend.setClusters([cluster, other])
        await backend.setWorkloads(ClusterWorkloads(), cluster: "other")
        let loading = store.show(other)
        #expect(store.workloads == nil && store.namespaceFilter == .all, "no stale rows of the previous cluster")
        await loading?.value
        #expect(store.workloads == ClusterWorkloads() && store.pods.isEmpty)
        await store.show(nil)?.value
        #expect(store.workloads == nil && store.unavailableReason != nil)
    }

    @Test func backendFailuresSurfaceAsLoadErrorsAndPollingStopsWithTheView() async throws {
        let failing = ClusterWorkloadsStore(
            backend: FailingBackend(error: .systemNotRunning), gate: PollingGate(engineRunning: true))
        let dev = KubernetesCluster(
            name: "dev", nodes: [.init(name: "dev", role: "control-plane", state: .running, cpus: 2, memoryMB: 2048)])
        await failing.show(dev)?.value
        #expect(failing.loadError == .systemNotRunning && failing.workloads == nil)

        let (store, _, _) = try await make()
        #expect(!store.poller.isRunning, "nothing polls until a view shows the store")
        store.startPolling()
        #expect(store.poller.isRunning)
        store.stopPolling()
        #expect(!store.poller.isRunning)
    }

    @Test func agesReadLikeKubectl() {
        #expect(KubeAge.format(seconds: 45) == "45s")
        #expect(KubeAge.format(seconds: 119) == "119s")
        #expect(KubeAge.format(seconds: 259) == "4m19s")
        #expect(KubeAge.format(seconds: 240) == "4m")
        #expect(KubeAge.format(seconds: 1_800) == "30m")
        #expect(KubeAge.format(seconds: 3 * 3600 + 12 * 60) == "3h12m")
        #expect(KubeAge.format(seconds: 10 * 3600) == "10h")
        #expect(KubeAge.format(seconds: 2 * 86_400 + 4 * 3600) == "2d4h")
        #expect(KubeAge.format(seconds: 41 * 86_400) == "41d")
        #expect(KubeAge.format(seconds: -5) == "0s")
        #expect(KubeAge.format(since: nil) == nil)
    }
}
