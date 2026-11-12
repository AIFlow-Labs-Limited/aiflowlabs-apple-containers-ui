import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

/// Decoding of the 1.7 cluster JSON and stats, and how cluster node containers are reconciled with
/// `container list` on CLIs that hide them.
@Suite("Kubernetes models and cluster nodes")
struct KubernetesModelTests {
    // MARK: ClusterResource decoding

    @Test func decodesTheSampleClusterList() throws {
        let resources = try ClusterSamples.clusterResources()
        #expect(resources.map(\.id) == ["cluster-dev", "staging", "temp"])
        let staging = resources[1]
        #expect(staging.name == "staging")
        #expect(staging.configuration.kubernetesVersion == "v1.34.11")
        #expect(staging.configuration.sharedImageStore && !staging.configuration.remove)
        #expect(staging.configuration.cni == nil && staging.configuration.fqdn == "staging.test")
        #expect(staging.configuration.nodes.map(\.roles) == [["control-plane"], ["worker"], ["worker"]])
        #expect(staging.configuration.nodes.allSatisfy { $0.kind == "linux" })
        #expect(staging.configuration.labels.isEmpty)
        #expect(staging.configuration.creationDate == CLIJSON.parseDate("2026-11-11T16:02:45Z"))
        #expect(staging.status.state == .degraded)
        #expect(staging.status.nodes.map(\.status) == [.running, .running, .stopped])
        #expect(staging.status.nodes.map(\.addresses) == [["192.168.64.8"], ["192.168.64.9"], nil])
        #expect(staging.status.nodes.allSatisfy { $0.ports == nil })
        #expect(resources[2].configuration.cni == "NONE")
    }

    /// The CLI prints one compact line with sorted keys; it must decode to the same values as the pretty file.
    @Test func compactOutputDecodesLikeThePrettyFixture() throws {
        let compact = ClusterSamples.data("cluster-list.compact.json")
        #expect(compact.split(separator: UInt8(ascii: "\n")).count == 1)
        #expect(
            String(decoding: compact, as: UTF8.self).hasPrefix(#"[{"configuration":{"cni":null,"creationDate":"2026-"#))
        #expect(try CLIJSON.decode([ClusterResource].self, from: compact) == ClusterSamples.clusterResources())
    }

    @Test func decodingIsLenient() throws {
        let json = #"""
            [
              {"configuration": {"name": "bare"}},
              {"id": "odd", "configuration": {"name": "odd", "kubernetesVersion": "v1.40.0", "newKey": [1, 2],
                "nodes": [{"name": "odd", "roles": ["control-plane"]}, {"roles": ["worker"]}]},
               "status": {"state": "hibernating", "futureField": true,
                 "nodes": [{"name": "odd", "status": "paused", "addresses": ["10.0.0.2", "fd00::2"],
                            "ports": ["6443->6443", "8080->80"]}, {"name": "ghost", "status": "running"}]}},
              {"status": {"state": "running"}}
            ]
            """#
        let list = try CLIJSON.decode(LossyArray<ClusterResource>.self, from: Data(json.utf8))
        #expect(list.droppedCount == 1, "an element without configuration.name is skipped, not fatal")
        let bare = list.elements[0]
        #expect(bare.id == "bare" && bare.status.state == .unknown && bare.configuration.nodes.isEmpty)
        #expect(
            !bare.configuration.remove && !bare.configuration.sharedImageStore && bare.configuration.creationDate == nil
        )

        let odd = list.elements[1]
        #expect(odd.status.state == .unknown, "unknown state strings never throw")
        #expect(odd.status.nodes[0].status == .unknown)
        #expect(odd.configuration.nodes.map(\.name) == ["odd"], "a node without a name is skipped")
        let cluster = KubernetesCluster(resource: odd)
        #expect(cluster.reportedState == nil)
        #expect(cluster.nodes.map(\.name) == ["odd", "ghost"], "a status-only node is still shown")
        #expect(cluster.nodes[0].address == "10.0.0.2,fd00::2" && cluster.nodes[0].ports == "6443->6443,8080->80")
        // No reported state: derived from the nodes, like the CLI does.
        #expect(cluster.state == .degraded && cluster.stateDescription == "degraded (1 of 2 up)")
        #expect(KubernetesCluster(resource: bare).state == .unknown)
    }

    @Test func stateIsDerivedTheWayTheCLIDoes() {
        func cluster(_ states: [ContainerState]) -> KubernetesCluster {
            KubernetesCluster(
                name: "c",
                nodes: states.enumerated().map { index, state in
                    .init(
                        name: "n\(index)", role: index == 0 ? "control-plane" : "worker", state: state, cpus: 2,
                        memoryMB: 2048)
                })
        }
        #expect(cluster([.running, .running]).state == .running)
        #expect(cluster([.running, .stopped, .stopping]).stateDescription == "degraded (1 of 3 up)")
        #expect(cluster([.stopped]).stateDescription == "stopped")
        #expect(cluster([]).stateDescription == "unknown")
        var reported = cluster([.running])
        reported.reportedState = .stopped
        #expect(reported.state == .stopped, "a reported state wins over the derived one")
    }

    @Test func nodeTableMergeMatchesByClusterAndNode() throws {
        let resources = try ClusterSamples.clusterResources()
        let table = ClusterSamples.clusterNodeTable()
        #expect(table.map(\.name) == ["cluster-dev", "staging", "temp"])
        // Same node name in another cluster's rows must not leak in.
        let other = [
            KubernetesCluster(
                name: "elsewhere", nodes: [.init(name: "staging", role: "x", state: .running, cpus: 64, memoryMB: 1)])
        ]
        #expect(KubernetesCluster(resource: resources[1], nodeTable: other).nodes[0].cpus == 0)
        let merged = KubernetesCluster(resource: resources[1], nodeTable: table)
        #expect(merged.nodes.map(\.cpus) == [2, 4, 4])
        // Role and state come from the JSON even when the table disagrees.
        var stale = table
        stale[1].nodes[0].role = "worker"
        stale[1].nodes[0].state = .stopped
        let fresh = KubernetesCluster(resource: resources[1], nodeTable: stale)
        #expect(fresh.nodes[0].role == "control-plane" && fresh.nodes[0].state == .running)
    }

    // MARK: Stats

    @Test func statsDecodeCPUUtilizationWhenPresent() throws {
        // Recorded from 1.7.1: every row has the figure, cluster nodes included (`stats` does not hide them).
        let new = try FixtureSet.cli171.stats()
        #expect(new.count >= 2 && new.allSatisfy { $0.cpuUtilization != nil })
        let first = try #require(new.first)
        #expect(first.reportedCPUPercent == first.cpuUtilization.map { $0 * 100 })
        let high = try CLIJSON.decode([ContainerStats].self, from: Data(#"[{"id":"a","cpuUtilization":1.4375}]"#.utf8))
        #expect(high[0].reportedCPUPercent == 143.75)
        let old = try Fixtures.stats()
        #expect(old.allSatisfy { $0.cpuUtilization == nil && $0.reportedCPUPercent == nil })
        // Junk never becomes a CPU figure.
        let odd = try CLIJSON.decode(
            [ContainerStats].self, from: Data(#"[{"id":"a","cpuUtilization":-1},{"id":"b","cpuUtilization":"x"}]"#.utf8)
        )
        #expect(odd.allSatisfy { $0.cpuUtilization == nil })
    }

    @Test func cpuPercentPrefersTheCLIFigureAndKeepsTheOldMath() {
        let before = ContainerStats(id: "a", cpuUsageUsec: 1_000_000, memoryUsageBytes: 1, memoryLimitBytes: 2)
        let after = ContainerStats(id: "a", cpuUsageUsec: 3_000_000, memoryUsageBytes: 1, memoryLimitBytes: 2)
        #expect(ContainerStats.cpuPercent(previous: before, current: after, interval: 4) == 50)
        var reported = after
        reported.cpuUtilization = 2.5
        #expect(ContainerStats.cpuPercent(previous: before, current: reported, interval: 4) == 250)
        #expect(ContainerStats.cpuPercent(previous: before, current: reported, interval: 0) == 250)
    }

    // MARK: Cluster nodes vs `container list`

    /// A node-shaped container: the recorded fixture with another id (and, optionally, the plugin label).
    private static func nodeJSON(_ fixture: String, renaming old: String, to id: String, plugin: String? = nil) -> Data
    {
        var text = Fixtures.text(fixture).replacingOccurrences(of: "\"\(old)\"", with: "\"\(id)\"")
        if let plugin {
            text = text.replacingOccurrences(
                of: #""com.apple.container.plugin": "builder""#, with: #""com.apple.container.plugin": "\#(plugin)""#)
        }
        return Data(text.utf8)
    }

    private func make(
        _ cli: KubernetesCLIFake, list: Data, _ extra: @escaping RecordingRunner.Handler
    )
        throws -> (CLIBackend, RecordingRunner)
    {
        let runner = RecordingRunner(
            handler: cli.handler { arguments in
                let args = Array(arguments.dropFirst())
                switch args {
                case ["k8s", "ls"]: return ProcessResult(stdout: Fixtures.data("k8s-list.txt"))
                case ["cluster", "list", "--format", "json"]:
                    return ProcessResult(stdout: ClusterSamples.data("cluster-list.json"))
                case ["cluster", "list", "--nodes"]:
                    return ProcessResult(stdout: ClusterSamples.data("cluster-list-nodes.txt"))
                case ["ls", "-a", "--format", "json"]: return ProcessResult(stdout: list)
                default: return extra(arguments)
                }
            })
        return (try CLIBackend.recording(runner), runner)
    }

    @Test func hiddenNodesAreAddedToTheContainerList() async throws {
        let inspect = ["inspect", "--", "cluster-dev", "staging", "staging-worker-1"]
        let (backend, runner) = try make(.cli171, list: Fixtures.data("containers.json")) { arguments in
            Array(arguments.dropFirst()) == inspect
                ? ProcessResult(stdout: Self.nodeJSON("container-inspect.json", renaming: "probe", to: "cluster-dev"))
                : ProcessResult(stdout: "[]")
        }
        // Before clusters were ever listed nothing is known, so nothing extra runs.
        #expect(try await backend.listContainers(includeStopped: true).map(\.id) == ["probe", "buildkit"])
        #expect(runner.commands == [["ls", "-a", "--format", "json"]])

        _ = try await backend.listClusters()
        let containers = try await backend.listContainers(includeStopped: true)
        #expect(containers.map(\.id) == ["probe", "buildkit", "cluster-dev"])
        // Only nodes reported running are inspected: `temp` and `staging-worker-2` may no longer exist.
        #expect(Array(runner.commands.suffix(2)) == [["ls", "-a", "--format", "json"], inspect])
    }

    @Test func aFailedInspectFallsBackToThePlainListing() async throws {
        let (backend, runner) = try make(.cli171, list: Fixtures.data("containers.json")) { arguments in
            Array(arguments.dropFirst()).first == "inspect"
                ? ProcessResult(exitCode: 1, stdout: "", stderr: "Error: container not found: staging\n")
                : ProcessResult(stdout: "[]")
        }
        _ = try await backend.listClusters()
        #expect(try await backend.listContainers(includeStopped: true).map(\.id) == ["probe", "buildkit"])
        // The stale names are forgotten until clusters are listed again: no second inspect.
        _ = try await backend.listContainers(includeStopped: true)
        #expect(runner.commands.filter { $0.first == "inspect" }.count == 1)
    }

    @Test func aCLIThatListsNodesIsLeftAlone() async throws {
        // 1.5 / 1.6: the node container is part of `container list`, labelled with the plugin name.
        let listed = Self.nodeJSON("containers.json", renaming: "buildkit", to: "k8s-dev", plugin: "k8s")
        let (backend, runner) = try make(.cli150, list: listed) { _ in ProcessResult(stdout: "[]") }
        _ = try await backend.listClusters()
        let containers = try await backend.listContainers(includeStopped: true)
        #expect(containers.map(\.id) == ["probe", "k8s-dev"])
        #expect(containers[1].isClusterNode && containers[1].isSystemManaged && !containers[0].isClusterNode)
        #expect(!runner.commands.contains { $0.first == "inspect" })
        _ = try await backend.listContainers(includeStopped: true)
        #expect(!runner.commands.contains { $0.first == "inspect" })
    }

    @Test func refusedNodeLifecycleIsExplained() async throws {
        // What 1.7.1 prints (recorded 2026-11-12): `start` without the `notFound:` prefix, the others with it.
        let notFound: @Sendable (String, String) -> ProcessResult = { verb, id in
            let message =
                verb == "start"
                ? "Error: container with ID \(id) not found\n"
                : "Error: notFound: \"container with ID \(id) not found\"\n"
            return ProcessResult(exitCode: 1, stdout: "", stderr: message)
        }
        let (backend, _) = try make(.cli171, list: Fixtures.data("containers.json")) { arguments in
            let args = Array(arguments.dropFirst())
            return ["start", "stop", "kill", "delete"].contains(args.first ?? "")
                ? notFound(args.first ?? "", args.last ?? "") : ProcessResult(stdout: "[]")
        }
        _ = try await backend.listClusters()
        do {
            try await backend.stopContainer("staging-worker-1", timeoutSeconds: nil, signal: nil)
            Issue.record("stopping a cluster node must fail")
        } catch let error as BackendError {
            guard case .unsupported = error else { Issue.record("expected .unsupported, got \(error)"); return }
            #expect(error.errorDescription?.contains("Kubernetes cluster “staging”") == true)
        }
        for refused in ["start", "kill", "delete"] {
            let error = await Self.backendError {
                switch refused {
                case "start": try await backend.startContainer("staging")
                case "kill": try await backend.killContainer("staging", signal: nil)
                default: try await backend.deleteContainer("staging", force: true)
                }
            }
            guard case .unsupported = error else {
                Issue.record("\(refused): expected .unsupported, got \(String(describing: error))")
                continue
            }
        }
        await #expect(throws: BackendError.notFound(kind: "container", id: "web")) {
            try await backend.deleteContainer("web", force: false)
        }
    }

    private static func backendError(_ body: () async throws -> Void) async -> BackendError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? BackendError
        }
    }
}
