import ContainerKitMock
import Foundation

@testable import ContainerKit

/// Help screens of the Kubernetes plugin per CLI release, and a `RecordingRunner` handler that plays one release.
///
/// - 1.5.0: **recorded** from the installed plugin (`Resources/cli-1.5.0/k8s-*-help.txt`).
/// - 1.6.0 / 1.6.1: derived from the ArgumentParser declarations at Apple's tags `1.6.0` / `1.6.1`
///   (`Sources/ContainerK8s/Commands/*.swift`, `Sources/ContainerCluster/Commands/*.swift`), laid out like the
///   recorded 1.5.0 screens.
/// - 1.7.1: derived, see `Resources/cli-1.7.1-derived/README.md`.
enum KubernetesCLIFake: CaseIterable {
    case cli150, cli160, cli161, cli171

    var word: String {
        switch self {
        case .cli150, .cli160: return "k8s"
        case .cli161, .cli171: return "cluster"
        }
    }

    var pluginHelp: String {
        switch self {
        case .cli150: return Fixtures.text("k8s-help.txt")
        case .cli160: return Self.pluginHelp16(word: "k8s", list: "List clusters and their nodes")
        case .cli161: return Self.pluginHelp16(word: "cluster", list: "List clusters and their nodes")
        case .cli171: return DerivedFixtures.text("cluster-help.txt")
        }
    }

    var createHelp: String {
        switch self {
        case .cli150: return Fixtures.text("k8s-create-help.txt")
        case .cli160: return Self.createHelp16(word: "k8s", defaultName: "k8s-dev")
        case .cli161: return Self.createHelp16(word: "cluster", defaultName: "cluster-dev")
        case .cli171: return DerivedFixtures.text("cluster-create-help.txt")
        }
    }

    var listHelp: String {
        switch self {
        case .cli150: return Fixtures.text("k8s-list-help.txt")
        case .cli160, .cli161: return Self.listHelp16(word: word)
        case .cli171: return DerivedFixtures.text("cluster-list-help.txt")
        }
    }

    /// `nil` for 1.7.1, which has no `load-image`.
    var loadImageHelp: String? {
        switch self {
        case .cli150: return Fixtures.text("k8s-load-image-help.txt")
        case .cli160: return Self.loadImageHelp16(word: "k8s", defaultName: "k8s-dev")
        case .cli161: return Self.loadImageHelp16(word: "cluster", defaultName: "cluster-dev")
        case .cli171: return nil
        }
    }

    /// The capabilities the app should detect for this release.
    var expected: KubernetesCapabilities {
        switch self {
        case .cli150: return .legacy
        case .cli160:
            return KubernetesCapabilities(
                commandWord: "k8s", supportsWorkers: true, supportsLoadImage: true, supportsLoadImageNodes: true)
        case .cli161:
            return KubernetesCapabilities(
                commandWord: "cluster", supportsWorkers: true, supportsLoadImage: true, supportsLoadImageNodes: true)
        case .cli171: return .modern
        }
    }

    /// What the real CLI prints for a subcommand it has no plugin for (recorded from 1.5.0, exit code 64).
    static func unknownPlugin(_ word: String) -> ProcessResult {
        ProcessResult(
            exitCode: 64, stdout: "",
            stderr: """
                Error: Plugins are unavailable. Start the container system services and retry:

                    container system start

                Check to see that the plugin exists under:
                  - /usr/local/libexec/container-plugins/\(word)
                  - /usr/local/libexec/container/plugins/\(word)

                Usage: container [--debug] <subcommand>
                  See 'container --help' for more information.

                """)
    }

    /// Answers the help probes of this release (and `system status`); everything else goes to `fallback`.
    func handler(
        fallback: @escaping RecordingRunner.Handler = { _ in ProcessResult(stdout: "[]") }
    ) -> RecordingRunner.Handler {
        { arguments in
            let args = Array(arguments.dropFirst())
            guard let first = args.first, KubernetesCapabilities.commandWords.contains(first) else {
                return args == ["system", "status"] ? ProcessResult(stdout: "running") : fallback(arguments)
            }
            guard first == self.word else { return Self.unknownPlugin(first) }
            switch Array(args.dropFirst()) {
            case ["--help"]: return ProcessResult(stdout: self.pluginHelp)
            case ["create", "--help"]: return ProcessResult(stdout: self.createHelp)
            case ["list", "--help"]: return ProcessResult(stdout: self.listHelp)
            case ["load-image", "--help"]:
                return self.loadImageHelp.map { ProcessResult(stdout: $0) }
                    ?? ProcessResult(exitCode: 64, stdout: "", stderr: "Error: Unexpected argument 'load-image'\n")
            default: return fallback(arguments)
            }
        }
    }

    /// The help probes detection runs for this release, in order.
    var probes: [[String]] {
        var commands: [[String]] = word == "cluster" ? [] : [["cluster", "--help"]]
        commands += [[word, "--help"], [word, "create", "--help"], [word, "list", "--help"]]
        if loadImageHelp != nil { commands.append([word, "load-image", "--help"]) }
        return commands
    }

    // MARK: 1.6.x help (derived)

    private static func pluginHelp16(word: String, list: String) -> String {
        """
        OVERVIEW: Manage local Kubernetes development clusters (EXPERIMENTAL)

        USAGE: \(word) <subcommand>

        OPTIONS:
          --version               Show the version.
          -h, --help              Show help information.

        SUBCOMMANDS:
          create                  Create and start a local Kubernetes cluster and
                                  optional worker nodes
          delete, rm              Delete a Kubernetes cluster and its nodes
          list, ls                \(list)
          load-image              Load a container image into a cluster's containerd
          write-config            Write the cluster context to a Kubernetes
                                  configuration file

          See '\(word) help <subcommand>' for detailed help.

        """
    }

    private static func createHelp16(word: String, defaultName: String) -> String {
        """
        OVERVIEW: Create and start a local Kubernetes cluster and optional worker nodes

        USAGE: \(word) create [--name <name>] [--rm] [--cpus <cpus>] [--memory <memory>] [--scheme <scheme>] [--max-concurrent-downloads <max-concurrent-downloads>] [--node-image <node-image>] [--cni <cni>] [--workers <workers>]

        RESOURCE OPTIONS:
          -c, --cpus <cpus>       Number of CPUs to allocate to the container
          -m, --memory <memory>   Amount of memory (1MiByte granularity), with optional
                                  K, M, G, T, or P suffix

        OPTIONS:
          --name <name>           Cluster name (default: \(defaultName))
          --rm, --remove          Remove the cluster container after it stops
          --node-image <node-image>
                                  Node image reference (default:
                                  docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95)
          --cni <cni>             Optional path to a CNI manifest to apply, or "NONE"
                                  to skip installing a CNI.
          --workers <workers>     Number of worker nodes to create (default: 0)
          --version               Show the version.
          -h, --help              Show help information.

        """
    }

    private static func listHelp16(word: String) -> String {
        """
        OVERVIEW: List clusters and their nodes

        USAGE: \(word) list

        OPTIONS:
          --version               Show the version.
          -h, --help              Show help information.

        """
    }

    private static func loadImageHelp16(word: String, defaultName: String) -> String {
        """
        OVERVIEW: Load a container image into a cluster's containerd

        USAGE: \(word) load-image [--name <name>] <image> [--platform <platform>] [--node <node> ...]

        ARGUMENTS:
          <image>                 Image reference to load (e.g. demo-api:latest)

        OPTIONS:
          --name <name>           Cluster name (default: \(defaultName))
          --platform <platform>   Platform of the image to load (format:
                                  os/arch[/variant], default: linux/arm64)
          --node <node>           Optionally load into specific nodes only
          --version               Show the version.
          -h, --help              Show help information.

        """
    }
}
