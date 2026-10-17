import Foundation
import Testing
import ContainerKit
import ContainerKitMock
@testable import AppCore

@MainActor
@Suite struct ResourceStoresTests {
    @Test func imagesInUseAndPull() async {
        let model = TestSupport.model()
        await model.containers.refresh()
        await model.images.refresh()
        #expect(!model.images.items.isEmpty)
        let inUse = model.images.inUseReferences
        #expect(inUse.contains("docker.io/library/postgres:16-alpine"))
        let task = model.images.pull("docker.io/library/redis:7")
        await task.wait()
        #expect(task.state == .succeeded)
        // completion refresh runs inside the task before `wait` returns
        #expect(model.images.items.contains { $0.reference == "docker.io/library/redis:7" })
    }

    @Test func imagesDeleteAndTag() async {
        let model = TestSupport.model()
        await model.images.refresh()
        guard let first = model.images.items.first else { Issue.record("no images"); return }
        await model.images.tag(first.reference, as: "example.com/copy:1")
        #expect(model.images.items.contains { $0.reference == "example.com/copy:1" })
        await model.images.delete(["example.com/copy:1"])
        #expect(!model.images.items.contains { $0.reference == "example.com/copy:1" })
        await model.images.delete(["does-not-exist:1"])
        #expect(model.images.lastError == .notFound(kind: "image", id: "does-not-exist:1"))
    }

    @Test func volumesCreateDelete() async {
        let model = TestSupport.model()
        await model.volumes.refresh()
        let before = model.volumes.items.count
        #expect(await model.volumes.create(name: "scratch", size: MemorySize(parsing: "1g")))
        #expect(model.volumes.items.count == before + 1)
        await model.volumes.delete(["scratch"])
        #expect(model.volumes.items.count == before)
    }

    @Test func networksCreateDeleteAndBuiltinError() async {
        let model = TestSupport.model()
        await model.networks.refresh()
        #expect(model.networks.items.contains { $0.name == "default" })
        #expect(await model.networks.create(name: "isolated", subnet: "192.168.70.0/24"))
        #expect(model.networks.items.contains { $0.name == "isolated" })
        await model.networks.delete(["default"])
        #expect(model.networks.lastError != nil)
        #expect(model.networks.items.contains { $0.name == "default" })
    }

    @Test func buildsRecordHistoryAndPersist() async throws {
        let url = TestSupport.historyURL()
        let backend = MockBackend()
        let tasks = TaskCenter()
        let store = BuildsStore(backend: backend, tasks: tasks, gate: PollingGate(engineRunning: true), historyURL: url)
        await store.refresh()
        #expect(store.builder != nil)
        let task = store.build(BuildSpec(contextDirectory: "/tmp/app", tag: "acdemo-api:dev"))
        await task.wait()
        for _ in 0..<50 where store.history.first?.status == .running { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.history.first?.status == .succeeded)
        #expect(store.history.first?.log.isEmpty == false)
        let reloaded = BuildsStore(backend: backend, tasks: tasks, gate: PollingGate(), historyURL: url)
        #expect(reloaded.history.first?.tag == "acdemo-api:dev")
    }

    @Test func machinesLifecycle() async {
        let model = TestSupport.model()
        await model.machines.refresh()
        #expect(model.machines.defaultMachine != nil)
        let task = model.machines.create(MachineSpec(image: "alpine:3.20", name: "box"))
        await task.wait()
        #expect(model.machines.items.contains { $0.name == "box" })
        await model.machines.setDefault("box")
        #expect(model.machines.defaultMachine?.name == "box")
        await model.machines.delete(["box"])
        #expect(!model.machines.items.contains { $0.name == "box" })
    }

    @Test func clustersAvailabilityAndCreate() async {
        let model = TestSupport.model()
        await model.clusters.refresh()
        #expect(model.clusters.available)
        let task = model.clusters.create(ClusterSpec(name: "dev"))
        await task.wait()
        #expect(model.clusters.items.map(\.name) == ["dev"])
        await model.clusters.delete(["dev"])
        #expect(model.clusters.items.isEmpty)
    }

    @Test func registriesLoginLogout() async {
        let model = TestSupport.model()
        await model.registries.refresh()
        #expect(await model.registries.login(server: "ghcr.io", username: "me", password: "secret"))
        #expect(model.registries.items.contains { $0.server == "ghcr.io" })
        await model.registries.logout(["ghcr.io"])
        #expect(!model.registries.items.contains { $0.server == "ghcr.io" })
    }

    @Test func systemStoreLoadsAndValidatesConfig() async {
        let model = TestSupport.model()
        await model.system.refresh()
        #expect(model.system.status?.isRunning == true)
        #expect(model.system.diskUsage != nil)
        #expect(model.system.dnsDomains.map(\.domain) == ["test"])
        await model.system.loadConfigTOML()
        #expect(model.system.configTOML.contains("[dns]"))
        #expect(await model.system.saveConfigTOML("[container]\ncpus = 4\n"))
        #expect(model.system.configTOML.contains("cpus = 4"))
        #expect(await model.system.saveConfigTOML("[container\ncpus = 4") == false)
        #expect(model.system.lastError != nil)
        #expect(await model.system.createDNSDomain("dev"))
        #expect(model.system.dnsDomains.contains { $0.domain == "dev" })
    }
}
