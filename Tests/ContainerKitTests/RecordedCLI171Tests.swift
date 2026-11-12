import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

/// Decoders and capability detectors against what container **1.7.1** really printed
/// (`Resources/cli-1.7.1/`, recorded by `scripts/record-fixtures.sh` on 2026-11-12).
@Suite("CLI 1.7.1 recorded fixtures")
struct RecordedCLI171Tests {
    let cli = FixtureSet.cli171

    // MARK: Capability detection from the real help screens

    @Test func kubernetesCapabilitiesFromRecordedHelp() {
        let detected = KubernetesCapabilities.detect(
            commandWord: "cluster", pluginHelp: cli.text("cluster-help.txt"),
            createHelp: cli.text("cluster-create-help.txt"), listHelp: cli.text("cluster-list-help.txt"))
        #expect(detected == .modern)
        #expect(detected.defaultClusterName == "cluster-dev")
        #expect(!detected.supportsLoadImage && !detected.supportsLoadImageNodes)
    }

    @Test func detectionThroughTheBackendRunsTheSameProbes() async throws {
        let fake = KubernetesCLIFake.cli171
        let runner = RecordingRunner(handler: fake.handler())
        let backend = try CLIBackend.recording(runner)
        #expect(try await backend.kubernetesCapabilities() == .modern)
        #expect(runner.commands == fake.probes)
    }

    /// `container --help`: the top-level commands the app relies on, and the two that are newer than 1.5.0.
    @Test func topLevelHelpListsCommitAndClean() {
        let help = cli.text("help.txt")
        let old = FixtureSet.cli150
        for command in [
            "create", "run", "start", "stop", "kill", "delete", "list", "logs", "exec", "inspect", "stats", "export",
            "copy", "prune", "image", "registry", "machine", "volume", "network", "system", "build", "builder",
            "cluster", "commit", "clean",
        ] {
            #expect(help.contains("\n  \(command)"), "`\(command)` is missing from `container --help`")
        }
        #expect(!help.contains("\n  k8s "), "1.7.1 has no `k8s` plugin word")
        #expect(!old.has("help.txt"), "the 1.5.0 recording predates help.txt")
        #expect(cli.text("commit-help.txt").contains("USAGE: container commit [--debug] <id> <reference>"))
        #expect(cli.text("clean-help.txt").contains("USAGE: container clean [--debug] [<container-ids> ...]"))
    }

    /// `supportsCommit()` asks `container commit --help`: exit 0 on 1.7.1, exit 64 "unknown command" on 1.5.0.
    @Test func commitProbeAgainstBothReleases() async throws {
        let help = cli.text("commit-help.txt")
        let new = try CLIBackend.recording(RecordingRunner { _ in ProcessResult(stdout: help) })
        #expect(await new.supportsCommit())
        let old = try CLIBackend.recording(
            RecordingRunner { _ in
                ProcessResult(exitCode: 64, stdout: "", stderr: "Error: unknown command 'commit'\n")
            })
        #expect(await !old.supportsCommit())
    }

    // MARK: Cluster listings

    @Test func clusterListRunning() throws {
        let resource = try #require(try cli.clusterResources().first)
        #expect(resource.id == "cd-it-v17-k8s" && resource.name == resource.id)
        #expect(resource.configuration.kubernetesVersion == "v1.35.5")
        #expect(resource.configuration.cni == nil, "`null`: the bundled CNI")
        #expect(resource.configuration.fqdn == "cd-it-v17-k8s.test", "<name>.<dns.domain property>")
        #expect(!resource.configuration.remove && !resource.configuration.sharedImageStore)
        #expect(resource.configuration.labels.isEmpty)
        #expect(resource.configuration.creationDate == CLIJSON.parseDate("2026-11-12T05:23:50Z"))
        #expect(resource.configuration.nodes.map(\.name) == ["cd-it-v17-k8s", "cd-it-v17-k8s-worker-1"])
        #expect(resource.configuration.nodes.map(\.roles) == [["control-plane"], ["worker"]])
        #expect(resource.configuration.nodes.allSatisfy { $0.kind == "linux" })
        #expect(resource.status.state == .running)
        #expect(resource.status.nodes.map(\.status) == [.running, .running])
        #expect(resource.status.nodes.map(\.addresses) == [["192.168.64.88"], ["192.168.64.89"]])
        #expect(resource.status.nodes.allSatisfy { $0.ports == nil }, "no published port when an FQDN is set")

        let cluster = try #require(try cli.clusters().first)
        #expect(cluster.state == .running && cluster.reportedState == .running)
        #expect(cluster.nodes.map(\.cpus) == [2, 2], "CPUS column of `cluster list --nodes`")
        #expect(cluster.nodes.map(\.memoryMB) == [2048, 2048], "`2 GB` in the MEMORY column")
        #expect(cluster.nodes[0].isControlPlane && cluster.nodes[1].role == "worker")
        #expect(cluster.nodes.map(\.address) == ["192.168.64.88", "192.168.64.89"])
    }

    @Test(arguments: ["degraded", "stopped"])
    func clusterListWithNodesDown(variant: String) throws {
        let resource = try #require(try cli.clusterResources(variant: variant).first)
        let cluster = try #require(try cli.clusters(variant: variant).first)
        let table = cli.text("cluster-list-\(variant).txt")
        if variant == "degraded" {
            #expect(resource.status.state == .degraded)
            #expect(resource.status.nodes.map(\.status) == [.running, .stopped])
            #expect(resource.status.nodes[1].addresses == nil, "left out, not an empty array")
            // The app's wording is the CLI's own.
            #expect(table.contains("degraded (1 of 2 up)") && cluster.stateDescription == "degraded (1 of 2 up)")
        } else {
            #expect(resource.status.state == .stopped)
            #expect(resource.status.nodes.allSatisfy { $0.status == .stopped && $0.addresses == nil })
            #expect(cluster.stateDescription == "stopped" && !cluster.isRunning)
        }
        // A node that is down but whose container still exists keeps its size in the node table.
        #expect(cluster.nodes.map(\.cpus) == [2, 2] && cluster.nodes.map(\.memoryMB) == [2048, 2048])
        #expect(cluster.nodes.last?.address == nil && cluster.nodes.last?.state == .stopped)
    }

    /// A single-node cluster created with `--rm`, running and then after its node powered off: the node
    /// container is removed, the cluster record stays (stopped) and the node table has no size for it.
    @Test func singleNodeClusterAndItsRemovedNode() throws {
        let single = try #require(try cli.clusters(variant: "single").first)
        #expect(single.name == "cd-it-v17-rm" && single.removeOnStop == true && single.state == .running)
        #expect(single.nodes.map(\.role) == ["control-plane,worker"])
        #expect(single.controlPlaneNode?.name == "cd-it-v17-rm" && single.workerNodes.isEmpty)
        #expect(single.nodes[0].cpus == 2 && single.nodes[0].memoryMB == 2048)

        let removed = try #require(try cli.clusters(variant: "removed").first)
        #expect(removed.state == .stopped && removed.nodes.map(\.state) == [.stopped])
        #expect(removed.nodes[0].cpus == 0 && removed.nodes[0].memoryMB == 0, "blank CPUS / MEMORY cells")
        #expect(removed.nodes[0].address == nil && removed.nodes[0].role == "control-plane,worker")
    }

    /// The CLI prints one compact line with sorted keys and nothing else on stdout.
    @Test(arguments: ["", "-degraded", "-stopped", "-single", "-removed"])
    func compactOutputIsOneLineAndDecodesLikeThePrettyFile(suffix: String) throws {
        let compact = cli.data("cluster-list\(suffix).compact.json")
        #expect(compact.split(separator: UInt8(ascii: "\n")).count == 1)
        #expect(String(decoding: compact, as: UTF8.self).hasPrefix(#"[{"configuration":{"cni":null,"creationDate":""#))
        #expect(
            try CLIJSON.decode([ClusterResource].self, from: compact)
                == cli.decode([ClusterResource].self, "cluster-list\(suffix).json"))
    }

    @Test func clusterTables() {
        let summary = TableParser.parse(cli.text("cluster-list.txt"))
        #expect(summary.headers == ["NAME", "NODES", "K8S VERSION", "STATE"])
        #expect(summary.records.first?["K8S VERSION"] == "v1.35.5" && summary.records.first?["NODES"] == "2")
        let nodes = TableParser.parse(cli.text("cluster-list-nodes.txt"))
        #expect(nodes.headers == ["CLUSTER", "NODE", "ROLE", "STATE", "CPUS", "MEMORY", "ADDR", "PORTS"])
        #expect(nodes.records.map { $0["CLUSTER"] } == ["cd-it-v17-k8s", "cd-it-v17-k8s"])
        #expect(nodes.records.map { $0["MEMORY"] } == ["2 GB", "2 GB"])
    }

    /// The hand-written scenarios (`ClusterSamples`) must not use a key the real CLI does not print.
    @Test func samplesUseOnlyRecordedKeys() throws {
        func keys(_ value: Any, _ path: String = "") -> Set<String> {
            if let object = value as? [String: Any] {
                return object.reduce(into: Set<String>()) { result, entry in
                    // `labels` is a free-form dictionary: its keys are data, not schema.
                    result.insert("\(path).\(entry.key)")
                    if entry.key != "labels" { result.formUnion(keys(entry.value, "\(path).\(entry.key)")) }
                }
            }
            if let array = value as? [Any] { return array.reduce(into: []) { $0.formUnion(keys($1, "\(path)[]")) } }
            return []
        }
        var recorded: Set<String> = []
        for name in ["cluster-list.json", "cluster-list-degraded.json", "cluster-list-single.json"] {
            recorded.formUnion(keys(try JSONSerialization.jsonObject(with: cli.data(name))))
        }
        let samples = keys(try JSONSerialization.jsonObject(with: ClusterSamples.data("cluster-list.json")))
        #expect(samples.subtracting(recorded).isEmpty, "\(samples.subtracting(recorded).sorted())")
        #expect(recorded.subtracting(samples).isEmpty, "\(recorded.subtracting(samples).sorted())")
    }

    // MARK: Cluster nodes are containers

    @Test func clusterNodesInspectLikeContainers() throws {
        let nodes = try cli.decode([Container].self, "cluster-node-inspect.json")
        #expect(Set(nodes.map(\.id)) == ["cd-it-v17-k8s", "cd-it-v17-k8s-worker-1"])
        #expect(nodes.allSatisfy { $0.isClusterNode && $0.isSystemManaged && $0.isRunning && !$0.isBuilder })
        #expect(nodes.allSatisfy { $0.labels[ResourceLabel.plugin] == "cluster" })
        #expect(Set(nodes.compactMap(\.role)) == ["control-plane", "worker"])
        #expect(nodes.allSatisfy { $0.configuration.resources.cpus == 2 })
        #expect(nodes.allSatisfy { $0.imageReference.hasPrefix("docker.io/kindest/node@sha256:") })
        // `container list` leaves them out (even with --all); `container stats` does not.
        let listed = Set(try cli.containers().map(\.id))
        #expect(listed == ["buildkit", "cd-it-v17-probe"])
        #expect(Set(try cli.stats().map(\.id)) == listed.union(nodes.map(\.id)))
    }

    /// The backend puts the hidden nodes back, reading the recorded files the way the real commands return them.
    @Test func hiddenNodesAreAddedFromTheRecordedOutput() async throws {
        let cli = cli
        let runner = RecordingRunner(
            handler: KubernetesCLIFake.cli171.handler { arguments in
                switch Array(arguments.dropFirst()) {
                case ["cluster", "list", "--format", "json"]:
                    return ProcessResult(stdout: cli.data("cluster-list.compact.json"))
                case ["cluster", "list", "--nodes"]: return ProcessResult(stdout: cli.data("cluster-list-nodes.txt"))
                case ["ls", "-a", "--format", "json"], ["ls", "--format", "json"]:
                    return ProcessResult(stdout: cli.data("containers.json"))
                case ["inspect", "--", "cd-it-v17-k8s", "cd-it-v17-k8s-worker-1"]:
                    return ProcessResult(stdout: cli.data("cluster-node-inspect.json"))
                default: return ProcessResult(exitCode: 1, stdout: "", stderr: "Error: unexpected \(arguments)\n")
                }
            })
        let backend = try CLIBackend.recording(runner)
        let clusters = try await backend.listClusters()
        #expect(clusters == (try cli.clusters()))
        let containers = try await backend.listContainers(includeStopped: true)
        #expect(
            Set(containers.map(\.id)) == ["buildkit", "cd-it-v17-probe", "cd-it-v17-k8s", "cd-it-v17-k8s-worker-1"])
        #expect(containers.filter(\.isClusterNode).count == 2)
        #expect(try await backend.listContainers(includeStopped: false).count == 4)
    }

    // MARK: Everything else decodes

    @Test func containersAndInspect() throws {
        let probe = try #require(try cli.containers().first { $0.id == "cd-it-v17-probe" })
        #expect(probe.isRunning && !probe.isSystemManaged)
        #expect(probe.configuration.publishedPorts.first?.display == "127.0.0.1:18517->8000/tcp")
        #expect(probe.configuration.mounts.first?.type.volumeName == "cd-it-v17-vol")
        #expect(probe.configuration.resources.memoryInBytes == 536_870_912)
        #expect(probe.labels == ["app": "probe"])
        // `--network cd-it-v17-net,alias=probe-alias`: stored with the DNS domain appended.
        let attachment = try #require(probe.configuration.networks.first)
        #expect(attachment.network == "cd-it-v17-net")
        #expect(attachment.options?.aliases == ["probe-alias.test"])
        #expect(probe.hostname == "cd-it-v17-probe.test.")
        #expect(probe.configuration.dns?.domain == "test")

        let inspected = try #require(try cli.decode([Container].self, "container-inspect.json").first)
        #expect(inspected.id == probe.id && inspected.configuration == probe.configuration)
        #expect(inspected.configuration.platform.variant == "v8")
        let builder = try #require(try cli.builder().first)
        #expect(builder.isBuilder && builder.isSystemManaged && !builder.isClusterNode)
    }

    @Test func imagesIncludeACommittedOneAndADigestOnlyOne() throws {
        let images = try cli.images()
        #expect(images.count >= 12)
        // Made by `container commit cd-it-v17-probe cd-it-v17-commit:latest`: the container's process becomes
        // the image's entrypoint and command, and its labels are kept.
        let committed = try #require(images.first { $0.reference == "docker.io/library/cd-it-v17-commit:latest" })
        #expect(committed.repository == "cd-it-v17-commit" && committed.tag == "latest")
        let config = try #require(committed.variants.first?.config?.config)
        #expect(config.entrypoint == ["python"] && config.cmd == ["-m", "http.server", "8000"])
        #expect(config.labels == ["app": "probe"])
        // The cluster node image is stored by digest, without a tag.
        let node = try #require(images.first { $0.reference.hasPrefix("docker.io/kindest/node@sha256:") })
        #expect(node.repository == "kindest/node" && node.tag == nil)
        let inspected = try #require(try cli.decode([Image].self, "image-inspect.json").first)
        #expect(inspected.variants.first?.config?.rootfs?.diffIDs.isEmpty == false)
    }

    @Test func statsCarryCPUUtilization() throws {
        let stats = try cli.stats()
        #expect(stats.count == 4)
        #expect(stats.allSatisfy { ($0.cpuUtilization ?? -1) >= 0 && $0.cpuUsageUsec > 0 && $0.memoryLimitBytes > 0 })
        #expect(try FixtureSet.cli150.stats().allSatisfy { $0.cpuUtilization == nil })
    }

    @Test func volumesNetworksMachinesRegistries() throws {
        let volume = try #require(try cli.volumes().first)
        #expect(volume.name == "cd-it-v17-vol" && volume.configuration.format == "ext4")
        #expect(try cli.decode([Volume].self, "volume-inspect.json") == [volume])

        let networks = try cli.networks()
        #expect(networks.map(\.name).sorted() == ["cd-it-v17-net", "default"])
        #expect(networks.first { $0.name == "default" }?.isBuiltin == true)
        let custom = try #require(try cli.decode([Network].self, "network-inspect.json").first)
        #expect(custom.name == "cd-it-v17-net" && !custom.isBuiltin && custom.status?.ipv4Subnet == "192.168.65.0/24")

        let machine = try #require(try cli.machines().first)
        #expect(machine.id == "cd-it-v17-m" && machine.status == .stopped && machine.isDefault)
        #expect(machine.cpus == 2 && machine.memory == 2 << 30)
        let inspected = try #require(try cli.decode([Machine].self, "machine-inspect.json").first)
        #expect(inspected.id == machine.id && inspected.homeMount == "none")
        #expect(inspected.image?.reference == "local/alpine-machine:latest")
        #expect(inspected.userSetup?.username == "user", "scrubbed by the recording script")

        #expect(CLIOutputParsing.registries(cli.data("registries.json")).isEmpty, "`[]`: no registry logins")
    }

    @Test func systemFiles() throws {
        let status = try cli.systemStatus()
        #expect(status.isRunning && status.client?.version == "1.7.1")
        #expect(TableParser.keyValues(cli.text("system-status.txt"))["client.version"] == "1.7.1")
        let version = TableParser.parse(cli.text("system-version.txt"))
        #expect(version.records.map { $0["VERSION"] } == ["1.7.1", "1.7.1"])
        let properties = try cli.systemProperties()
        #expect(properties.dns?.domain == "test")
        #expect(properties.container?.cpus == 4 && properties.container?.memory == "1gb")
        #expect(properties.build?.image?.hasPrefix("ghcr.io/apple/container-builder-shim/builder:") == true)
        let usage = try cli.diskUsage()
        #expect(usage.images.total == 17 && usage.volumes.total == 1 && usage.containers.active == 5)
    }
}
