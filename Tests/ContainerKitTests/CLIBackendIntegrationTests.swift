import Foundation
import Testing

@testable import ContainerKit

/// Hits the real `container` CLI. Read-only except for one container and one (cached) image pull that the
/// test creates itself. Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@Suite(
    "CLIBackend Integration", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_INTEGRATION"] == "1",
        "set CONTAINER_DESKTOP_INTEGRATION=1 to run against the real CLI"))
struct CLIBackendIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    @Test func systemStatusIsRunning() async throws {
        let status = try await backend.systemStatus()
        #expect(status.isRunning, "start the engine with `container system start`")
        #expect(status.client?.version.isEmpty == false)
        #expect(await backend.clientVersion() == status.client?.version)
    }

    @Test func readOnlyListings() async throws {
        let all = try await backend.listContainers(includeStopped: true)
        let running = try await backend.listContainers(includeStopped: false)
        #expect(running.allSatisfy { $0.isRunning })
        #expect(Set(running.map(\.id)).isSubset(of: Set(all.map(\.id))))
        if let first = all.first {
            #expect(try await backend.inspectContainer(first.id).id == first.id)
        }
        _ = try await backend.containerStats(ids: running.map(\.id))

        let images = try await backend.listImages()
        if let image = images.first {
            #expect(try await backend.inspectImage(image.reference).reference == image.reference)
        }
        let volumes = try await backend.listVolumes()
        if let volume = volumes.first {
            #expect(try await backend.inspectVolume(volume.name).name == volume.name)
        }
        let networks = try await backend.listNetworks()
        #expect(networks.contains { $0.isBuiltin })
        if let network = networks.first {
            #expect(try await backend.inspectNetwork(network.name).name == network.name)
        }
        let usage = try await backend.diskUsage()
        #expect(usage.images.total >= images.count)  // df also counts hidden infra images (vminit, builder)
        _ = try await backend.systemProperties()
        _ = try await backend.listDNSDomains()
        _ = try await backend.listRegistries()
        let machines = try await backend.listMachines()
        if let machine = machines.first {
            #expect(try await backend.inspectMachine(machine.id).id == machine.id)
        }
        _ = try await backend.builderStatus()
        let k8s = try await backend.checkKubernetesAvailable()
        #expect(await backend.kubernetesAvailable() == k8s)
        if k8s { _ = try await backend.listClusters() }
        let logs = try await backend.systemLogs(lines: 5)
        #expect(logs.count <= 5)
    }

    @Test func missingResourcesMapToNotFound() async throws {
        let ghost = "cd-kit-ghost-\(UUID().uuidString.prefix(8).lowercased())"
        await #expect(throws: BackendError.notFound(kind: "container", id: ghost)) {
            _ = try await backend.inspectContainer(ghost)
        }
        await #expect(throws: BackendError.notFound(kind: "volume", id: ghost)) {
            _ = try await backend.inspectVolume(ghost)
        }
        await #expect(throws: BackendError.notFound(kind: "network", id: ghost)) {
            _ = try await backend.inspectNetwork(ghost)
        }
        await #expect(throws: BackendError.notFound(kind: "machine", id: ghost)) {
            _ = try await backend.inspectMachine(ghost)
        }
        await #expect(throws: BackendError.notFound(kind: "container", id: ghost)) {
            _ = try await backend.execCapture(ghost, command: ["true"], workingDirectory: nil)
        }
    }

    @Test func pullCachedImageStreams() async throws {
        var lines: [OutputLine] = []
        for try await line in backend.pullImage("alpine:3.22", platform: nil) { lines.append(line) }
        let image = try await backend.inspectImage("alpine:3.22")
        #expect(image.reference.hasSuffix("alpine:3.22"))
    }

    @Test func containerLifecycle() async throws {
        let name = "cd-kit-test-\(UUID().uuidString.lowercased())"
        var spec = RunSpec(image: "alpine:3.22")
        spec.name = name
        spec.command = ["sh", "-c", "echo hello; sleep 60"]
        do {
            let id = try await backend.createContainer(spec)
            #expect(id == name)
            #expect(try await backend.inspectContainer(name).state != .running)

            try await backend.startContainer(name)
            #expect(try await backend.listContainers(includeStopped: false).contains { $0.id == name })

            var sawHello = false
            for _ in 0..<40 where !sawHello {
                var lines: [String] = []
                for try await line in backend.containerLogs(name, follow: false, boot: false, tail: nil) {
                    lines.append(line.text)
                }
                sawHello = lines.contains("hello")
                if !sawHello { try await Task.sleep(for: .milliseconds(250)) }
            }
            #expect(sawHello)

            let exec = try await backend.execCapture(
                name, command: ["sh", "-c", "echo from-exec; exit 3"], workingDirectory: "/tmp")
            #expect(exec.exitCode == 3)
            #expect(exec.stdout.contains("from-exec"))

            // Following logs must end (and kill the child) when the consumer stops listening.
            for try await line in backend.containerLogs(name, follow: true, boot: false, tail: 10)
            where line.text == "hello" { break }

            try await backend.stopContainer(name, timeoutSeconds: 1, signal: nil)
            #expect(try await backend.inspectContainer(name).state == .stopped)
            try await backend.deleteContainer(name, force: false)
            #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id == name })
        } catch {
            try? await backend.deleteContainer(name, force: true)
            throw error
        }
    }
}
