import Foundation
import Testing
import ContainerKit
import ContainerKitMock
@testable import AppCore

@MainActor
@Suite struct ContainersStoreTests {
    let gate = PollingGate(engineRunning: true)

    @Test func refreshLoadsFixtures() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        #expect(store.items.count >= 4)
        #expect(store.items.contains { $0.id == "db" })
        #expect(store.lastError == nil)
        #expect(!store.isLoading)
    }

    @Test func filtersStoppedAndSearch() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        store.showStopped = false
        #expect(store.filtered.allSatisfy { $0.isRunning })
        store.showStopped = true
        store.searchText = "postgres"
        #expect(store.filtered.map(\.id) == ["db"])
    }

    @Test func groupsByProjectLabel() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        let groups = store.groupedByProject
        let demo = groups.first { $0.project == "acdemo" }
        #expect(Set(demo?.containers.map(\.id) ?? []) == ["db", "api"])
        #expect(groups.last?.project == nil)
    }

    @Test func stopStartDeleteMutate() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        await store.stop(["db"])
        #expect(store.container(id: "db")?.isRunning == false)
        await store.start(["db"])
        #expect(store.container(id: "db")?.isRunning == true)
        await store.delete(["old-job"])
        #expect(store.container(id: "old-job") == nil)
        #expect(store.lastError == nil)
    }

    @Test func deletingRunningWithoutForceCapturesError() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        await store.delete(["db"], force: false)
        guard case .commandFailed = store.lastError else { Issue.record("expected commandFailed, got \(String(describing: store.lastError))"); return }
        #expect(store.container(id: "db") != nil)
    }

    @Test func errorsLandInLastError() async {
        let store = ContainersStore(backend: FailingBackend(error: .systemNotRunning), gate: gate)
        await store.refresh()
        #expect(store.lastError == .systemNotRunning)
        #expect(store.items.isEmpty)
    }

    @Test func cpuPercentFromTwoSamples() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        let t0 = Date()
        await store.refreshStats(now: t0)
        #expect(store.cpuPercent.isEmpty) // one sample is not enough
        await store.refreshStats(now: t0.addingTimeInterval(2))
        #expect(!store.cpuPercent.isEmpty)
        #expect(store.cpuPercent.values.allSatisfy { $0 > 0 })
        #expect(store.totalCPUPercent > 0)
        #expect(store.totalMemoryBytes > 0)
    }

    @Test func unexpectedExitIsReported() async {
        let backend = MockBackend()
        let store = ContainersStore(backend: backend, gate: gate)
        var exited: [String] = []
        store.onUnexpectedExit = { exited.append($0.id) }
        await store.refresh()
        try? await backend.stopContainer("db", timeoutSeconds: nil, signal: nil) // stopped behind the store's back
        await store.stop(["api"]) // user-initiated: not reported
        #expect(exited == ["db"])
    }
}
