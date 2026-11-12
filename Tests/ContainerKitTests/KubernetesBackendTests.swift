import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

/// `CLIBackend` against fake CLIs of each release: detection flow, caching, listing and commands.
@Suite("CLIBackend Kubernetes across CLI releases")
struct KubernetesBackendTests {
    /// A backend whose runner plays `cli`; cluster listings answer from fixtures.
    private func make(
        _ cli: KubernetesCLIFake, extra: @escaping RecordingRunner.Handler = { _ in ProcessResult(stdout: "[]") }
    ) throws -> (CLIBackend, RecordingRunner) {
        let runner = RecordingRunner(
            handler: cli.handler { arguments in
                switch Array(arguments.dropFirst()) {
                case ["k8s", "ls"]: return ProcessResult(stdout: Fixtures.data("k8s-list.txt"))
                case ["cluster", "list", "--format", "json"]:
                    return ProcessResult(stdout: ClusterSamples.data("cluster-list.compact.json"))
                case ["cluster", "list", "--nodes"]:
                    return ProcessResult(stdout: ClusterSamples.data("cluster-list-nodes.txt"))
                default: return extra(arguments)
                }
            })
        return (try CLIBackend.recording(runner), runner)
    }

    // MARK: Detection

    @Test(arguments: KubernetesCLIFake.allCases)
    func detectsOnceAndCaches(_ cli: KubernetesCLIFake) async throws {
        let (backend, runner) = try make(cli)
        #expect(try await backend.kubernetesCapabilities() == cli.expected)
        #expect(runner.commands == cli.probes)
        #expect(try await backend.checkKubernetesAvailable())
        #expect(await backend.kubernetesAvailable())
        #expect(try await backend.kubernetesCapabilities() == cli.expected)
        #expect(runner.commands == cli.probes, "capabilities are cached; no further help probes")
        await backend.forgetKubernetesCapabilities()
        _ = try await backend.kubernetesCapabilities()
        #expect(runner.commands == cli.probes + cli.probes)
    }

    @Test func missingPluginIsNilAndProbedAgain() async throws {
        let runner = RecordingRunner { arguments in
            let args = Array(arguments.dropFirst())
            return args == ["system", "status"]
                ? ProcessResult(stdout: "running") : KubernetesCLIFake.unknownPlugin(args[0])
        }
        let backend = try CLIBackend.recording(runner)
        #expect(try await backend.kubernetesCapabilities() == nil)
        #expect(try await !backend.checkKubernetesAvailable())
        let probe = [["cluster", "--help"], ["k8s", "--help"], ["system", "status"]]
        #expect(runner.commands == probe + probe, "a missing plugin is not cached")
        await #expect(throws: BackendError.self) { _ = try await backend.listClusters() }
    }

    @Test func stoppedEngineIsNotAMissingPlugin() async throws {
        // Engine stopped: the same "Plugins are unavailable" text, and `system status` fails too.
        let runner = RecordingRunner { arguments in
            let args = Array(arguments.dropFirst())
            return args == ["system", "status"]
                ? ProcessResult(exitCode: 1, stdout: "", stderr: "apiserver is not running\n")
                : KubernetesCLIFake.unknownPlugin(args[0])
        }
        let backend = try CLIBackend.recording(runner)
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.kubernetesCapabilities() }
        await #expect(throws: BackendError.systemNotRunning) { _ = try await backend.checkKubernetesAvailable() }
        #expect(await !backend.kubernetesAvailable())
    }

    @Test func usageErrorDropsTheCachedCapabilities() async throws {
        // The CLI was replaced behind the cache: the plugin no longer knows `ls`.
        let (backend, runner) = try make(.cli150) { _ in
            ProcessResult(exitCode: 64, stdout: "", stderr: "Error: Unknown option '--name'\n")
        }
        _ = try await backend.kubernetesCapabilities()
        await #expect(throws: BackendError.self) { try await backend.deleteCluster("dev") }
        _ = try await backend.kubernetesCapabilities()
        #expect(runner.commands.filter { $0 == ["k8s", "--help"] }.count == 2)
    }

    @Test func fingerprintFollowsTheBinaryOnDisk() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cd-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("1.5.0".utf8).write(to: file)
        let before = CLIBackend.fingerprint(of: file.path)
        #expect(before == CLIBackend.fingerprint(of: file.path))
        try Data("1.7.1 is bigger".utf8).write(to: file)
        #expect(before != CLIBackend.fingerprint(of: file.path))
        // An unreadable path still yields a stable value.
        #expect(
            CLIBackend.fingerprint(of: "/nonexistent/container") == CLIBackend.fingerprint(of: "/nonexistent/container")
        )
    }

    // MARK: Listing

    @Test func oldCLIListsFromTheTableExactlyAsBefore() async throws {
        let (backend, runner) = try make(.cli150)
        let clusters = try await backend.listClusters()
        #expect(clusters == CLIOutputParsing.clusters(Fixtures.text("k8s-list.txt")))
        #expect(clusters.map(\.name) == ["k8s-dev", "staging", "cd-ui-test"])
        #expect(runner.commands.last == ["k8s", "ls"])
        // Nothing a table-only CLI cannot know is invented.
        #expect(
            clusters.allSatisfy { $0.kubernetesVersion == nil && $0.reportedState == nil && $0.sharedImageStore == nil }
        )
        #expect(clusters.map(\.state) == [.running, .stopped, .running])
    }

    @Test func renamedPluginStillListsFromTheTable() async throws {
        // 1.6.1: `cluster ls` prints the per-node table with CLUSTER filled in.
        let table = """
            CLUSTER      NODE                  ROLE           STATE    CPUS  MEMORY   ADDR           PORTS
            cluster-dev  cluster-dev           control-plane  running  4     8192 MB  192.168.64.5
            cluster-dev  cluster-dev-worker-1  worker         stopped  4     8192 MB

            """
        let (backend, runner) = try make(.cli161) { arguments in
            Array(arguments.dropFirst()) == ["cluster", "ls"]
                ? ProcessResult(stdout: table) : ProcessResult(stdout: "[]")
        }
        let clusters = try await backend.listClusters()
        #expect(runner.commands.last == ["cluster", "ls"])
        #expect(clusters.map(\.name) == ["cluster-dev"])
        #expect(clusters[0].nodes.map(\.name) == ["cluster-dev", "cluster-dev-worker-1"])
        #expect(clusters[0].state == .degraded)
        #expect(clusters[0].stateDescription == "degraded (1 of 2 up)")
    }

    @Test func jsonCLIListsRecordsAndMergesTheNodeTable() async throws {
        let (backend, runner) = try make(.cli171)
        let clusters = try await backend.listClusters()
        #expect(
            Array(runner.commands.suffix(2)) == [
                ["cluster", "list", "--format", "json"], ["cluster", "list", "--nodes"],
            ])
        #expect(clusters.map(\.name) == ["cluster-dev", "staging", "temp"])
        #expect(clusters.map(\.kubernetesVersion) == ["v1.35.5", "v1.34.11", "v1.35.5"])
        #expect(clusters.map(\.state) == [.running, .degraded, .stopped])
        #expect(clusters.map(\.sharedImageStore) == [false, true, false])

        let staging = clusters[1]
        #expect(staging.stateDescription == "degraded (2 of 3 up)")
        #expect(staging.nodes.map(\.role) == ["control-plane", "worker", "worker"])
        #expect(staging.workerNodes.map(\.name) == ["staging-worker-1", "staging-worker-2"])
        #expect(staging.controlPlaneNode?.name == "staging")
        // CPU and memory come from the --nodes table (the JSON has neither).
        #expect(staging.nodes.map(\.cpus) == [2, 4, 4])
        #expect(staging.nodes.map(\.memoryMB) == [4096, 8192, 8192])
        #expect(staging.nodes.map(\.address) == ["192.168.64.8", "192.168.64.9", nil])
        #expect(staging.nodes.map(\.state) == [.running, .running, .stopped])
        #expect(staging.fqdn == "staging.test")

        // A `--rm` cluster whose node container is gone: listed as stopped, no size.
        let temp = clusters[2]
        #expect(temp.removeOnStop == true && temp.cni == "NONE")
        #expect(temp.nodes.map(\.cpus) == [0] && temp.nodes.map(\.memoryMB) == [0])
        #expect(clusters[0].nodes[0].role == "control-plane,worker")
    }

    @Test func jsonListingSurvivesAMissingNodeTable() async throws {
        let runner = RecordingRunner(
            handler: KubernetesCLIFake.cli171.handler { arguments in
                switch Array(arguments.dropFirst()) {
                case ["cluster", "list", "--format", "json"]:
                    return ProcessResult(stdout: ClusterSamples.data("cluster-list.json"))
                case ["cluster", "list", "--nodes"]:
                    return ProcessResult(exitCode: 1, stdout: "", stderr: "Error: boom\n")
                default: return ProcessResult(stdout: "[]")
                }
            })
        let clusters = try await CLIBackend.recording(runner).listClusters()
        #expect(clusters.map(\.name) == ["cluster-dev", "staging", "temp"])
        #expect(clusters.flatMap(\.nodes).allSatisfy { $0.cpus == 0 && $0.memoryMB == 0 })
        #expect(clusters[1].state == .degraded)
    }

    @Test func emptyJSONListingSkipsTheNodeTable() async throws {
        let runner = RecordingRunner(handler: KubernetesCLIFake.cli171.handler())
        #expect(try await CLIBackend.recording(runner).listClusters().isEmpty)
        #expect(runner.commands.last == ["cluster", "list", "--format", "json"])
    }

    // MARK: Commands

    @Test func commandsUseTheDetectedWord() async throws {
        let (backend, runner) = try make(.cli171)
        var spec = ClusterSpec(name: "dev")
        spec.workerGroups = [ClusterWorkerGroup(count: 2, cpus: 4, memory: MemorySize(parsing: "8g"))]
        spec.sharedImageStore = true
        #expect(await drain(backend.createCluster(spec)).error == nil)
        try await backend.deleteCluster("dev")
        #expect(
            Array(runner.commands.suffix(2)) == [
                [
                    "cluster", "create", "--name", "dev", "--workers", "count=2,cpus=4,memory=8G",
                    "--shared-image-store",
                ],
                ["cluster", "delete", "--name", "dev"],
            ])
        #expect(runner.calls.dropLast().last?.streamed == true)
    }

    @Test func unsupportedOptionsFailBeforeAnythingIsCreated() async throws {
        let (old, oldRunner) = try make(.cli150)
        var spec = ClusterSpec(name: "dev")
        spec.sharedImageStore = true
        let created = await drain(old.createCluster(spec))
        #expect(created.error.map { if case BackendError.unsupported = $0 { true } else { false } } == true)
        #expect(oldRunner.commands == KubernetesCLIFake.cli150.probes, "only help probes ran")

        let (new, newRunner) = try make(.cli171)
        let loaded = await drain(new.loadImage("app:1", intoCluster: "dev", nodes: [], platform: nil))
        #expect(loaded.error.map { if case BackendError.unsupported = $0 { true } else { false } } == true)
        #expect(newRunner.commands == KubernetesCLIFake.cli171.probes)

        // Operands that look like options never reach detection.
        let bad = await drain(new.createCluster(ClusterSpec(name: "--rm")))
        #expect(bad.error != nil)
        #expect(newRunner.commands == KubernetesCLIFake.cli171.probes)
    }

    @Test func loadImageTargetsNodesWhereTheCLICan() async throws {
        let (backend, runner) = try make(.cli160)
        _ = await drain(backend.loadImage("app:1", intoCluster: "dev", nodes: ["dev-worker-1"], platform: nil))
        #expect(
            runner.commands.last == ["k8s", "load-image", "--name", "dev", "--node", "dev-worker-1", "--", "app:1"])
    }
}
