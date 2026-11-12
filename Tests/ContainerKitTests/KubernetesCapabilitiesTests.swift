import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

/// Capability detection from help text, and the argv generated for each capability set.
@Suite("Kubernetes capabilities")
struct KubernetesCapabilitiesTests {
    // MARK: Detection from help text

    @Test(arguments: KubernetesCLIFake.allCases)
    func detectsCapabilitiesFromHelp(_ cli: KubernetesCLIFake) {
        let detected = KubernetesCapabilities.detect(
            commandWord: cli.word, pluginHelp: cli.pluginHelp, createHelp: cli.createHelp, listHelp: cli.listHelp,
            loadImageHelp: cli.loadImageHelp)
        #expect(detected == cli.expected)
    }

    @Test func recorded150HelpIsTheLegacyPlugin() {
        let cli = KubernetesCLIFake.cli150
        #expect(KubernetesCapabilities.subcommands(in: cli.pluginHelp).contains("load-image"))
        #expect(
            KubernetesCapabilities.subcommands(in: cli.pluginHelp).isSuperset(of: ["create", "delete", "rm", "ls"]))
        #expect(!KubernetesCapabilities.hasOption("--workers", in: cli.createHelp))
        #expect(!KubernetesCapabilities.hasOption("--format", in: cli.listHelp))
        // 1.5.0 prints the default twice: "Cluster name (default: k8s-dev) (default: k8s-dev)".
        #expect(KubernetesCapabilities.defaultName(in: cli.createHelp) == "k8s-dev")
    }

    @Test func recorded171HelpIsTheModernPlugin() {
        let cli = KubernetesCLIFake.cli171
        let subcommands = KubernetesCapabilities.subcommands(in: cli.pluginHelp)
        #expect(subcommands == ["create", "delete", "rm", "list", "ls", "write-config"])
        #expect(!subcommands.contains("load-image"))
        #expect(KubernetesCapabilities.hasOption("--workers", in: cli.createHelp))
        #expect(cli.createHelp.contains("count=<n>,cpus=<n>,memory=<size>"))
        #expect(KubernetesCapabilities.hasOption("--shared-image-store", in: cli.createHelp))
        #expect(KubernetesCapabilities.hasOption("--format", in: cli.listHelp))
        #expect(KubernetesCapabilities.hasOption("--nodes", in: cli.listHelp))
        #expect(KubernetesCapabilities.defaultName(in: cli.createHelp) == "cluster-dev")
        #expect(cli.expected.displayCommand == "container cluster")
        #expect(cli.expected.workersUnavailableReason == nil)
        #expect(cli.expected.sharedImageStoreUnavailableReason == nil)
    }

    @Test func optionsMatchWholeWordsOnly() {
        let help = "  --node-image <node-image>  Node image\n  --nodes   Show nodes\n"
        #expect(!KubernetesCapabilities.hasOption("--node", in: help))
        #expect(KubernetesCapabilities.hasOption("--nodes", in: help))
        #expect(KubernetesCapabilities.hasOption("--node-image", in: help))
        #expect(KubernetesCapabilities.hasOption("--node", in: "USAGE: x [--node <node> ...]"))
        #expect(!KubernetesCapabilities.hasOption("--format", in: ""))
    }

    @Test func workerGroupsNeedTheCountSyntaxInHelp() {
        let plain = KubernetesCLIFake.cli161
        let detected = KubernetesCapabilities.detect(
            commandWord: "cluster", pluginHelp: plain.pluginHelp, createHelp: plain.createHelp,
            listHelp: plain.listHelp)
        #expect(detected.supportsWorkers && !detected.supportsWorkerGroups)
        // No load-image help given: `--node` cannot be assumed.
        #expect(detected.supportsLoadImage && !detected.supportsLoadImageNodes)
    }

    @Test func unavailableReasonsNameTheCommand() {
        #expect(KubernetesCapabilities.legacy.workersUnavailableReason?.contains("`k8s create`") == true)
        #expect(
            KubernetesCapabilities.legacy.sharedImageStoreUnavailableReason?.contains("--shared-image-store") == true)
        #expect(KubernetesCLIFake.cli161.expected.workerGroupsUnavailableReason != nil)
        #expect(KubernetesCapabilities(commandWord: "cluster").defaultClusterName == "cluster-dev")
        #expect(KubernetesCapabilities(commandWord: "k8s").defaultClusterName == "k8s-dev")
    }

    // MARK: Argument generation

    private func spec(_ configure: (inout ClusterSpec) -> Void = { _ in }) -> ClusterSpec {
        var spec = ClusterSpec(name: "dev")
        spec.cpus = 2
        spec.memory = MemorySize(parsing: "4g")
        configure(&spec)
        return spec
    }

    @Test(arguments: KubernetesCLIFake.allCases)
    func plainClusterUsesTheDetectedWord(_ cli: KubernetesCLIFake) throws {
        #expect(
            try spec().createArguments(for: cli.expected) == [
                cli.word, "create", "--name", "dev", "-c", "2", "-m", "4G",
            ]
        )
    }

    @Test func workersNeedACLIWithWorkers() throws {
        let withWorkers = spec { $0.workers = 3 }
        #expect(throws: BackendError.self) { try withWorkers.createArguments(for: .legacy) }
        #expect(withWorkers.unsupportedOption(for: .legacy)?.errorDescription?.contains("--workers") == true)
        for cli in [KubernetesCLIFake.cli160, .cli161, .cli171] {
            #expect(
                try withWorkers.createArguments(for: cli.expected)
                    == [cli.word, "create", "--name", "dev", "-c", "2", "-m", "4G", "--workers", "3"])
        }
    }

    @Test func sizedWorkerGroupsNeedTheGroupSyntax() throws {
        let grouped = spec {
            $0.workerGroups = [
                ClusterWorkerGroup(count: 2, cpus: 4, memory: MemorySize(parsing: "8g")),
                ClusterWorkerGroup(count: 1, cpus: 2),
                ClusterWorkerGroup(count: 0, cpus: 8),  // empty groups are dropped
            ]
        }
        #expect(grouped.totalWorkers == 3)
        #expect(
            try grouped.createArguments(for: .modern) == [
                "cluster", "create", "--name", "dev", "-c", "2", "-m", "4G",
                "--workers", "count=2,cpus=4,memory=8G", "--workers", "count=1,cpus=2",
            ])
        let on16 = grouped.unsupportedOption(for: KubernetesCLIFake.cli161.expected)
        #expect(on16?.errorDescription?.contains("count=") == true)
        #expect(grouped.unsupportedOption(for: .legacy)?.errorDescription?.contains("--workers") == true)
    }

    @Test func defaultSizedGroupsCollapseIntoOneCount() throws {
        let mixed = spec {
            $0.workers = 2
            $0.workerGroups = [ClusterWorkerGroup(count: 3)]
        }
        // Understood by every CLI that has --workers, including 1.6's plain number.
        #expect(try mixed.createArguments(for: KubernetesCLIFake.cli160.expected).suffix(2) == ["--workers", "5"])
        #expect(try mixed.createArguments(for: .modern).suffix(2) == ["--workers", "5"])
        let sized = spec {
            $0.workers = 2
            $0.workerGroups = [ClusterWorkerGroup(count: 1, memory: MemorySize(parsing: "2g"))]
        }
        #expect(
            try sized.createArguments(for: .modern).suffix(4) == ["--workers", "2", "--workers", "count=1,memory=2G"])
    }

    @Test func sharedImageStoreAndWorkerLimit() throws {
        let shared = spec { $0.sharedImageStore = true }
        #expect(try shared.createArguments(for: .modern).last == "--shared-image-store")
        for cli in [KubernetesCLIFake.cli150, .cli160, .cli161] {
            let error = shared.unsupportedOption(for: cli.expected)
            #expect(error?.errorDescription?.contains("--shared-image-store") == true)
        }
        let tooMany = spec { $0.workers = ClusterWorkerGroup.maxWorkers + 1 }
        #expect(tooMany.unsupportedOption(for: .modern) != nil)
        #expect(spec { $0.workers = ClusterWorkerGroup.maxWorkers }.unsupportedOption(for: .modern) == nil)
    }

    @Test func allOptionsInOrder() throws {
        let full = spec {
            $0.nodeImage = "docker.io/kindest/node:v1.34.11"
            $0.cniManifest = "/tmp/cni.yaml"
            $0.removeOnStop = true
            $0.workers = 1
            $0.sharedImageStore = true
        }
        let expected = [
            "--name", "dev", "-c", "2", "-m", "4G", "--node-image", "docker.io/kindest/node:v1.34.11",
            "--cni", "/tmp/cni.yaml", "--rm", "--workers", "1", "--shared-image-store",
        ]
        #expect(try full.createArguments(for: .modern) == ["cluster", "create"] + expected)
        // The capability-agnostic form used where no CLI is known.
        #expect(full.cliArguments == expected)
    }

    @Test func loadImageArgumentsPerCapability() throws {
        #expect(
            try CLIBackend.loadImageArguments(
                "app:1", cluster: "dev", nodes: [], platform: .arm64, capabilities: .legacy)
                == ["k8s", "load-image", "--name", "dev", "--platform", "linux/arm64", "--", "app:1"])
        #expect(
            try CLIBackend.loadImageArguments(
                "app:1", cluster: nil, nodes: ["dev-worker-1", "dev-worker-2"], platform: nil,
                capabilities: KubernetesCLIFake.cli161.expected)
                == ["cluster", "load-image", "--node", "dev-worker-1", "--node", "dev-worker-2", "--", "app:1"])
        // 1.5.0 has no --node; 1.7 has no load-image at all.
        #expect(throws: BackendError.self) {
            try CLIBackend.loadImageArguments("app:1", cluster: nil, nodes: ["n"], platform: nil, capabilities: .legacy)
        }
        do {
            _ = try CLIBackend.loadImageArguments(
                "app:1", cluster: "dev", nodes: [], platform: nil, capabilities: .modern)
            Issue.record("load-image must be unsupported on a CLI without it")
        } catch let error as BackendError {
            #expect(error.errorDescription?.contains("shared image store") == true)
        }
    }
}
