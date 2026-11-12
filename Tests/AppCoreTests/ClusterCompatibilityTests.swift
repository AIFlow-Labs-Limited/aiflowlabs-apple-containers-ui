import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

/// The Kubernetes forms, store and stats against an old (1.5-style `k8s`) and a new (1.7-style `cluster`) CLI.
@MainActor
@Suite struct ClusterCompatibilityTests {
    private let host = HostResources(cpus: 12, memoryBytes: 64 << 30)
    /// 1.6: `--workers N` only, still `load-image`.
    private let middle = KubernetesCapabilities(
        commandWord: "cluster", supportsWorkers: true, supportsLoadImage: true, supportsLoadImageNodes: true)

    // MARK: Form

    @Test func formFollowsTheInstalledPlugin() {
        #expect(ClusterForm(host: host).name == "k8s-dev")
        #expect(ClusterForm(host: host).previewCommand() == "container k8s create --name k8s-dev -c 3 -m 16G")
        let modern = ClusterForm(host: host, capabilities: .modern)
        #expect(modern.name == "cluster-dev")
        #expect(modern.previewCommand() == "container cluster create --name cluster-dev -c 3 -m 16G")
        #expect(modern.isValid)
    }

    @Test func unsupportedOptionsNeverReachTheCommand() {
        var form = ClusterForm(host: host)
        form.workers = 3
        form.sharedImageStore = true
        form.addSizedWorkers()
        #expect(form.spec.workers == nil && form.spec.workerGroups.isEmpty && !form.spec.sharedImageStore)
        #expect(form.totalWorkers == 0 && form.isValid)
        #expect(form.previewCommand() == "container k8s create --name k8s-dev -c 3 -m 16G")

        form.capabilities = middle
        #expect(form.spec.workers == 3 && form.spec.workerGroups.isEmpty && !form.spec.sharedImageStore)
        #expect(form.previewCommand() == "container cluster create --name k8s-dev -c 3 -m 16G --workers 3")
    }

    @Test func workerGroupsAndSharedStoreOnAModernCLI() {
        var form = ClusterForm(host: host, capabilities: .modern)
        form.name = "big"
        form.workers = 1
        form.addSizedWorkers()
        form.sizedWorkers[0].count = 2
        form.sizedWorkers[0].cpus = 4
        form.sizedWorkers[0].memoryGB = 8
        form.sharedImageStore = true
        #expect(form.totalWorkers == 3)
        #expect(
            form.previewCommand()
                == "container cluster create --name big -c 3 -m 16G --workers 1 --workers count=2,cpus=4,memory=8G --shared-image-store"
        )
        // The preview is exactly what the backend would run.
        let argv = (try? form.spec.createArguments(for: .modern)) ?? []
        #expect("container " + argv.joined(separator: " ") == form.previewCommand())
        // New rows start at the default node size.
        #expect(ClusterForm(host: host, capabilities: .modern).sizedWorkers.isEmpty)
        form.addSizedWorkers()
        #expect(
            form.sizedWorkers[1].cpus == host.clusterDefaultCPUs
                && form.sizedWorkers[1].memoryGB == host.clusterDefaultMemoryGB)
    }

    @Test func duplicateNamesAreRejected() {
        var form = ClusterForm(host: host, capabilities: .modern, existingNames: ["cluster-dev", "staging"])
        // The sheet opens on a free name, not on an error.
        #expect(form.name == "cluster-dev-2" && form.isValid)
        form.name = "staging"
        #expect(form.nameError == "A cluster named “staging” already exists.")
        #expect(!form.isValid)
        form.name = "fresh"
        #expect(form.nameError == nil && form.isValid)
    }

    @Test func copyableCommandsUseThePluginWord() {
        #expect(
            KubectlCommands.quick("x", capabilities: .modern).map(\.command).last == "container cluster delete --name x"
        )
        #expect(!KubectlCommands.quick("x", capabilities: .modern).contains { $0.command.contains("load-image") })
        #expect(
            KubectlCommands.quick("x", capabilities: middle).contains {
                $0.command == "container cluster load-image --name x IMAGE"
            })
        #expect(
            LoadImageCommand.preview(cluster: "dev", reference: "", platform: nil)
                == "container k8s load-image --name dev IMAGE")
        #expect(
            LoadImageCommand.preview(cluster: "dev", reference: "app:1", platform: .arm64, capabilities: middle)
                == "container cluster load-image --name dev --platform linux/arm64 app:1")
    }

    @Test func sharedImageStoreWarningIsApplesText() {
        #expect(SharedImageStoreNotes.warnings.count == 3)
        #expect(SharedImageStoreNotes.warnings[0].contains("private images you pulled with your registry credentials"))
        #expect(SharedImageStoreNotes.warnings[1].contains("without the pod's pull secrets"))
    }

    // MARK: Presentation

    @Test func clusterPresentation() throws {
        let clusters = try DerivedFixtures.clusters()
        #expect(clusters.map(\.stateTitle) == ["Running", "Degraded (2 of 3 up)", "Stopped"])
        #expect(clusters.map(\.nodesSummary) == ["1 node", "1 control plane + 2 workers", "1 node"])
        #expect(clusters.map(\.cniTitle) == ["kindnet (built in)", "kindnet (built in)", "None"])
        #expect(clusters[1].nodes.map(\.sizeText) == ["2 CPUs · 4 GB", "4 CPUs · 8 GB", "4 CPUs · 8 GB"])
        #expect(clusters[2].nodes[0].sizeText == nil, "a node whose container is gone has no size")
        var custom = clusters[0]
        custom.cni = "/Users/me/cilium.yaml"
        #expect(custom.cniTitle == "cilium.yaml")
        let odd = KubernetesCluster.Node(name: "n", role: "worker", state: .running, cpus: 1, memoryMB: 1536)
        #expect(odd.sizeText == "1 CPU · 1536 MB")
    }

    // MARK: Store

    @Test func storeReportsTheOldPlugin() async {
        let model = TestSupport.model(MockBackend(kubernetes: .legacy))
        await model.clusters.refresh()
        #expect(model.clusters.available && model.clusters.capabilities == .legacy)
        #expect(model.clusters.items.isEmpty)
        var spec = ClusterSpec(name: "dev")
        spec.workers = 2
        let refused = model.clusters.create(spec)
        await refused.wait()
        guard case .failed(.unsupported) = refused.state else {
            Issue.record("workers must be refused by a 1.5-style CLI, got \(refused.state)")
            return
        }
        #expect(model.clusters.items.isEmpty)
        await model.clusters.create(ClusterSpec(name: "dev")).wait()
        #expect(model.clusters.items.map(\.name) == ["dev"])
        #expect(model.clusters.items[0].kubernetesVersion == nil && model.clusters.items[0].sharedImageStore == nil)
    }

    @Test func storeReportsTheNewPlugin() async {
        let backend = MockBackend(kubernetes: .modern)
        let model = TestSupport.model(backend)
        await model.clusters.refresh()
        #expect(model.clusters.capabilities == .modern)
        #expect(model.clusters.effectiveCapabilities.commandWord == "cluster")
        #expect(model.clusters.items.map(\.name) == ["cluster-dev", "staging", "temp"])
        #expect(model.clusters.items[1].state == .degraded)

        var spec = ClusterSpec(name: "big")
        spec.nodeImage = "docker.io/kindest/node:v1.34.11"
        spec.workerGroups = [ClusterWorkerGroup(count: 2, cpus: 4, memory: MemorySize(bytes: 8 << 30))]
        spec.sharedImageStore = true
        await model.clusters.create(spec).wait()
        let big = model.clusters.items.first { $0.name == "big" }
        #expect(big?.nodes.map(\.name) == ["big", "big-worker-1", "big-worker-2"])
        #expect(big?.nodes.map(\.role) == ["control-plane", "worker", "worker"])
        #expect(big?.workerNodes.map(\.memoryMB) == [8192, 8192])
        #expect(big?.sharedImageStore == true && big?.kubernetesVersion == "v1.34.11" && big?.state == .running)

        let load = model.clusters.loadImage("app:1", into: "big")
        await load.wait()
        guard case .failed(.unsupported) = load.state else {
            Issue.record("load-image must be refused by a 1.7-style CLI, got \(load.state)")
            return
        }
    }

    @Test func storePicksUpAChangedPlugin() async {
        let backend = MockBackend(kubernetes: nil)
        let model = TestSupport.model(backend)
        await model.clusters.refresh()
        #expect(!model.clusters.available && model.clusters.capabilities == nil)
        #expect(model.clusters.effectiveCapabilities == .legacy)

        // A missing plugin is remembered until someone asks again (e.g. the CLI version changed).
        await backend.setKubernetes(.legacy)
        await model.clusters.refresh()
        #expect(!model.clusters.available)
        await model.clusters.recheckAvailability()
        #expect(model.clusters.capabilities == .legacy)

        // An available plugin is re-read on every refresh, so an upgrade shows up without a restart.
        await backend.setKubernetes(.modern)
        await model.clusters.refresh()
        #expect(model.clusters.capabilities == .modern)

        // Engine down: capabilities are unknown, not gone.
        await backend.setSystemRunning(false)
        await model.clusters.refresh()
        #expect(model.clusters.available && model.clusters.capabilities == .modern)
        #expect(model.clusters.loadError == .systemNotRunning)
    }

    // MARK: Stats

    @Test func historyUsesTheCLIFigureFromTheFirstSample() {
        let history = ContainerStatsHistory()
        let reported = ContainerStats(
            id: "web", cpuUsageUsec: 5_000_000, memoryUsageBytes: 100, memoryLimitBytes: 1000, cpuUtilization: 0.25)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(history.append(reported, at: t0).cpuPercent == 25)
        // Later samples keep using the CLI's own measurement, not the gap between our polls.
        var next = reported
        next.cpuUsageUsec = 99_000_000
        next.cpuUtilization = 1.5
        #expect(history.append(next, at: t0.addingTimeInterval(2)).cpuPercent == 150)
        // Without the field (1.5 / 1.6) the old two-sample math applies.
        var old = next
        old.id = "old"
        old.cpuUtilization = nil
        #expect(history.append(old, at: t0).cpuPercent == 0)
        old.cpuUsageUsec += 1_000_000
        #expect(abs(history.append(old, at: t0.addingTimeInterval(2)).cpuPercent - 50) < 0.0001)
    }

    @Test func storeShowsCPUAfterOneSampleOnANewCLI() async {
        let store = ContainersStore(backend: MockBackend(kubernetes: .modern), gate: PollingGate(engineRunning: true))
        await store.refresh()
        await store.refreshStats(now: Date())
        #expect(!store.cpuPercent.isEmpty)
        #expect(store.cpuPercent.values.allSatisfy { $0 > 0 })
    }
}
