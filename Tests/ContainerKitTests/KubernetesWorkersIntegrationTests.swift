import Foundation
import Testing

@testable import ContainerKit

/// What newer plugins add (container 1.7): a sized worker group, the shared image store, the JSON listing,
/// `--nodes`, nodes hidden from `container list`, and a node going down. Part of the same serialized suite as `KubernetesIntegrationTests`,
/// so only one `cd-it-…` cluster exists at a time. Each test returns early on a CLI whose `--help` lacks the
/// feature (nothing here looks at a version number).
extension KubernetesIntegrationTests {
    private static var kubeconfig: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kube/config")
    }

    @Test(.timeLimit(.minutes(20)))
    func createsAClusterWithASizedWorkerGroup() async throws {
        let capabilities = try #require(try await backend.kubernetesCapabilities())
        guard capabilities.supportsWorkerGroups, capabilities.listsJSON, capabilities.listsNodes else { return }
        let word = capabilities.commandWord
        let name = Integration.uniqueName("k8s")
        let worker = "\(name)-worker-1"
        // The plugin edits ~/.kube/config. Keep a copy so a mismatch after `delete` can be repaired by hand.
        let kubeconfigBefore = try? Data(contentsOf: Self.kubeconfig)
        let backup = FileManager.default.temporaryDirectory.appending(path: "\(name)-kubeconfig-backup")
        try kubeconfigBefore?.write(to: backup)

        var spec = ClusterSpec(name: name)
        spec.cpus = 2
        spec.memory = MemorySize(bytes: 2 << 30)
        spec.workerGroups = [ClusterWorkerGroup(count: 1, cpus: 2, memory: MemorySize(bytes: 2 << 30))]
        spec.sharedImageStore = capabilities.supportsSharedImageStore
        #expect(try spec.createArguments(for: capabilities).contains("count=1,cpus=2,memory=2G"))
        var output: [String] = []
        do {
            for try await line in backend.createCluster(spec) { output.append(line.text) }
            #expect(output.count > 5, "`create` streams its progress")
            #expect(output.contains { $0.contains("Joining worker \(worker)") })

            // The raw JSON: one compact line on stdout, strictly decodable, with the keys the model mirrors.
            let raw = try await backend.execute([word, "list", "--format", "json"])
            #expect(raw.stdoutText.split(whereSeparator: \.isNewline).count == 1)
            let resources = try CLIJSON.decode([ClusterResource].self, from: raw.stdout)
            let resource = try #require(resources.first { $0.name == name })
            #expect(resource.id == name)
            #expect(resource.configuration.nodes.map(\.name) == [name, worker])
            #expect(resource.configuration.nodes.map(\.roles) == [["control-plane"], ["worker"]])
            #expect(resource.configuration.creationDate != nil)
            #expect(resource.status.nodes.allSatisfy { $0.addresses?.isEmpty == false })
            let object = try #require(
                (JSONSerialization.jsonObject(with: raw.stdout) as? [[String: Any]])?.first {
                    $0["id"] as? String == name
                }
            )
            let configuration = try #require(object["configuration"] as? [String: Any])
            #expect(
                Set(configuration.keys).isSuperset(of: [
                    "name", "kubernetesVersion", "cni", "fqdn", "remove", "sharedImageStore", "nodes", "creationDate",
                    "labels",
                ]))
            #expect(configuration["cni"] is NSNull, "an unset --cni is an explicit null")

            // What the app shows: the JSON merged with the `--nodes` table.
            let cluster = try #require(try await backend.listClusters().first { $0.name == name })
            #expect(cluster.reportedState == .running && cluster.stateDescription == "running")
            #expect(cluster.kubernetesVersion?.hasPrefix("v") == true)
            #expect(cluster.sharedImageStore == spec.sharedImageStore && cluster.removeOnStop == false)
            #expect(cluster.nodes.map(\.name) == [name, worker])
            #expect(cluster.nodes[0].isControlPlane && cluster.workerNodes.map(\.name) == [worker])
            #expect(cluster.nodes.map(\.cpus) == [2, 2])
            #expect(cluster.nodes.map(\.memoryMB) == [2048, 2048])
            #expect(cluster.nodes.allSatisfy { $0.state == .running && $0.address?.isEmpty == false })

            // The kubeconfig has a context named after the cluster.
            let config = String(decoding: try Data(contentsOf: Self.kubeconfig), as: UTF8.self)
            #expect(config.contains("name: \(name)"))

            if spec.sharedImageStore { try await checkSharedImageStore(cluster: name) }
            try await checkNodeContainers(name: name, worker: worker)
            try await checkANodeGoingDown(name: name, worker: worker)

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

        // `delete` took exactly its own context out again.
        if let kubeconfigBefore {
            let after = try Data(contentsOf: Self.kubeconfig)
            #expect(after == kubeconfigBefore, "~/.kube/config changed; the copy from before is at \(backup.path)")
            if after == kubeconfigBefore { try? FileManager.default.removeItem(at: backup) }
        } else if let after = try? Data(contentsOf: Self.kubeconfig) {
            #expect(!String(decoding: after, as: UTF8.self).contains("name: \(name)"))
        }
    }

    /// A pod runs an image that exists only in the local image store (a fresh tag of a local image), without any
    /// `load-image`. `kubectl` is the one inside the control-plane node, so the Mac needs none.
    private func checkSharedImageStore(cluster: String) async throws {
        let image = "\(cluster)-local:only"
        let kubectl = ["kubectl", "--kubeconfig", "/etc/kubernetes/admin.conf"]
        try await backend.tagImage(Integration.busyBoxImage, newReference: image)
        do {
            let run = try await backend.execCapture(
                cluster,
                command: kubectl + [
                    "run", "cd-it-hello", "--image=\(image)", "--restart=Never", "--command", "--", "sh", "-c",
                    "echo hello-from-the-local-store",
                ], workingDirectory: nil)
            try #require(run.exitCode == 0, "kubectl run: \(run.stderr)")
            var phase = ""
            for _ in 0..<90 where phase != "Succeeded" {
                let pod = try await backend.execCapture(
                    cluster, command: kubectl + ["get", "pod", "cd-it-hello", "-o", "jsonpath={.status.phase}"],
                    workingDirectory: nil)
                phase = pod.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if phase != "Succeeded" { try await Task.sleep(for: .seconds(1)) }
            }
            #expect(phase == "Succeeded", "the pod could not use the local image (phase: \(phase))")
            let logs = try await backend.execCapture(
                cluster, command: kubectl + ["logs", "cd-it-hello"], workingDirectory: nil)
            #expect(logs.stdout.contains("hello-from-the-local-store"))
        } catch {
            try? await backend.deleteImage(image)
            throw error
        }
        try await backend.deleteImage(image)
    }

    /// Nodes are containers: in the app's list and stats whether or not `container list` prints them, and
    /// protected from start / stop / kill / delete when it does not.
    private func checkNodeContainers(name: String, worker: String) async throws {
        let listed = try await backend.decodeList(Container.self, ["ls", "-a", "--format", "json"]).map(\.id)
        let hiddenByCLI = !listed.contains(name)
        #expect(listed.contains(worker) == !hiddenByCLI, "control plane and worker are listed or hidden together")

        for includeStopped in [true, false] {
            let containers = try await backend.listContainers(includeStopped: includeStopped)
            let nodes = containers.filter { $0.id == name || $0.id == worker }
            #expect(nodes.count == 2, "includeStopped \(includeStopped): \(containers.map(\.id))")
            #expect(nodes.allSatisfy { $0.isRunning && $0.isClusterNode && $0.isSystemManaged })
            #expect(nodes.allSatisfy { $0.configuration.resources.cpus == 2 })
        }
        #expect(try await backend.inspectContainer(worker).isClusterNode)

        let stats = try await backend.containerStats(ids: [name, worker])
        #expect(Set(stats.map(\.id)) == [name, worker])
        let everything = try await backend.containerStats(ids: [])
        #expect(Set(everything.map(\.id)).isSuperset(of: [name, worker]), "`stats` without ids covers nodes too")
        let exec = try await backend.execCapture(worker, command: ["hostname"], workingDirectory: nil)
        #expect(exec.exitCode == 0 && exec.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == worker)

        guard hiddenByCLI else { return }
        for action in ["stop", "kill", "start", "delete"] {
            let failure = await Integration.backendError {
                switch action {
                case "stop": try await backend.stopContainer(worker, timeoutSeconds: 1, signal: nil)
                case "kill": try await backend.killContainer(worker, signal: nil)
                case "start": try await backend.startContainer(worker)
                default: try await backend.deleteContainer(worker, force: true)
                }
            }
            guard case .unsupported(_, let reason) = failure else {
                Issue.record("\(action): expected unsupported, got \(String(describing: failure))")
                continue
            }
            #expect(reason.contains("Kubernetes cluster “\(name)”"), "\(action): \(reason)")
        }
        #expect(try await backend.inspectContainer(worker).isRunning, "the refused commands changed nothing")
    }

    /// Powers the worker off from the inside (the CLI refuses to stop it) and expects `degraded (1 of 2 up)`.
    private func checkANodeGoingDown(name: String, worker: String) async throws {
        _ = try await backend.execCapture(
            worker, command: ["sh", "-c", "kill -s RTMIN+4 1 || systemctl poweroff --force"], workingDirectory: nil)
        var cluster: KubernetesCluster?
        for _ in 0..<60 {
            cluster = try await backend.listClusters().first { $0.name == name }
            if cluster?.reportedState == .degraded { break }
            try await Task.sleep(for: .seconds(1))
        }
        let degraded = try #require(cluster)
        #expect(degraded.reportedState == .degraded && degraded.stateDescription == "degraded (1 of 2 up)")
        #expect(degraded.nodes.map(\.state) == [.running, .stopped])
        #expect(degraded.nodes[1].address == nil)
        #expect(degraded.nodes[1].cpus == 2 && degraded.nodes[1].memoryMB == 2048, "a stopped node keeps its size")
        // Only running nodes are added to the container list.
        let containers = try await backend.listContainers(includeStopped: true)
        #expect(containers.contains { $0.id == name })
        #expect(try await !backend.listContainers(includeStopped: false).contains { $0.id == worker })
    }
}
