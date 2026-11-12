import Foundation
import Testing

@testable import ContainerKit

/// The Kubernetes plugin of the installed `container` CLI: capability detection, listing, and one small
/// cluster created and deleted again. The node image (`kindest/node`) must be local.
///
/// The cluster is named `cd-it-…` and is deleted in a cleanup path that also runs on failure. The plugin
/// itself adds a context of the same name to `~/.kube/config` on create and removes it on delete.
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@Suite("Kubernetes Integration", .serialized, .enabled(if: Integration.isEnabled, Integration.hint))
struct KubernetesIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    @Test func detectsThePluginOfTheInstalledCLI() async throws {
        let capabilities = try #require(try await backend.kubernetesCapabilities())
        #expect(try await backend.checkKubernetesAvailable())
        #expect(await backend.kubernetesAvailable())
        #expect(try await backend.kubernetesCapabilities() == capabilities)  // cached answer agrees
        await backend.forgetKubernetesCapabilities()
        #expect(try await backend.kubernetesCapabilities() == capabilities)  // and so does a fresh detection

        let version = await backend.clientVersion() ?? ""
        guard version.hasPrefix("1.5.") else { return }
        // 1.5.0: the `k8s` plugin, single-node clusters, a per-node table and `load-image` without `--node`.
        #expect(capabilities == KubernetesCapabilities.legacy)
        #expect(capabilities.commandWord == "k8s")
        #expect(capabilities.displayCommand == "container k8s")
        #expect(capabilities.defaultClusterName == "k8s-dev")
        #expect(!capabilities.supportsWorkers)
        #expect(!capabilities.supportsWorkerGroups)
        #expect(!capabilities.supportsSharedImageStore)
        #expect(capabilities.supportsLoadImage)
        #expect(!capabilities.supportsLoadImageNodes)
        #expect(!capabilities.listsJSON)
        #expect(!capabilities.listsNodes)
    }

    @Test func listsClustersWhenThereMayBeNone() async throws {
        let clusters = try await backend.listClusters()
        #expect(!clusters.contains { $0.name.hasPrefix("cd-it-") }, "a previous run left a cluster behind")
        for cluster in clusters { #expect(!cluster.nodes.isEmpty, "\(cluster.name)") }
    }

    @Test func optionsTheCLILacksFailBeforeAnythingRuns() async throws {
        let capabilities = try #require(try await backend.kubernetesCapabilities())
        let name = Integration.uniqueName("k8s")
        var spec = ClusterSpec(name: name)
        var expected = 0
        if !capabilities.supportsWorkers {
            spec.workers = 1
            expected += 1
        } else if !capabilities.supportsSharedImageStore {
            spec.sharedImageStore = true
            expected += 1
        }
        guard expected > 0 else { return }
        let failure = await Integration.backendError { for try await _ in backend.createCluster(spec) {} }
        guard case .unsupported = failure else {
            Issue.record("expected unsupported, got \(String(describing: failure))")
            try? await backend.deleteCluster(name)
            return
        }
        #expect(try await !backend.listClusters().contains { $0.name == name })
    }

    @Test(.timeLimit(.minutes(20)))
    func createsListsAndDeletesACluster() async throws {
        let name = Integration.uniqueName("k8s")
        var spec = ClusterSpec(name: name)
        spec.cpus = 2
        spec.memory = MemorySize(bytes: 2 << 30)
        var output: [String] = []
        do {
            for try await line in backend.createCluster(spec) { output.append(line.text) }

            let clusters = try await backend.listClusters()
            let cluster = try #require(clusters.first { $0.name == name }, "listed: \(clusters.map(\.name))")
            #expect(cluster.isRunning)
            #expect(cluster.nodes.count == 1)
            let node = try #require(cluster.nodes.first)
            #expect(node.isControlPlane)
            #expect(node.state == .running)
            #expect(node.cpus == 2)
            #expect(node.memoryMB == 2048)
            #expect(node.address?.isEmpty == false)

            // The node is a container the app files under "system containers".
            let containers = try await backend.listContainers(includeStopped: true)
            let container = try #require(
                containers.first { $0.id == node.name }, "node \(node.name) is not a container")
            #expect(container.isRunning)
            #expect(container.isSystemManaged)

            try await backend.deleteCluster(name)
        } catch {
            try? await backend.deleteCluster(name)
            await removeLeftovers(of: name)
            Issue.record("output of `create`:\n\(output.suffix(40).joined(separator: "\n"))")
            throw error
        }
        #expect(try await !backend.listClusters().contains { $0.name == name })
        await removeLeftovers(of: name)
        #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id.hasPrefix(name) })
    }

    /// Node containers of a cluster this suite created that `delete` did not remove (only `cd-it-…` names).
    private func removeLeftovers(of name: String) async {
        guard name.hasPrefix("cd-it-") else { return }
        for container in (try? await backend.listContainers(includeStopped: true)) ?? []
        where container.id.hasPrefix(name) {
            try? await backend.deleteContainer(container.id, force: true)
        }
    }
}
