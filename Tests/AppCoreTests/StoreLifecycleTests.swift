import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

/// A store whose refresh result is scripted, to test error ownership and load sequencing without a backend.
@MainActor
final class ScriptedStore: BackendStore {
    var isLoading = false
    var loadError: BackendError?
    var actionError: BackendError?
    var lastError: BackendError? {
        get { actionError ?? loadError }
        set { actionError = newValue; if newValue == nil { loadError = nil } }
    }
    var refreshFailure: BackendError?
    var value: Int?

    func refresh() async {
        let failure = refreshFailure
        if let v = await load({ () async throws -> Int in
            if let failure { throw failure }
            return 1
        }) {
            value = v
        }
    }

    /// Loads `result` after `delay` through the shared `load` sequencing (same call site every time).
    func delayedLoad(_ result: Int, after delay: Duration) async {
        if let v = await load(
            site: "delayed",
            { () async throws -> Int in
                try await Task.sleep(for: delay)
                return result
            })
        {
            value = v
        }
    }
}

@MainActor
@Suite struct StoreErrorLifetimeTests {
    @Test func actionErrorSurvivesASuccessfulPollTick() async {
        let store = ScriptedStore()
        let ok = await store.perform { throw BackendError.other("delete failed") }
        #expect(!ok)
        #expect(store.actionError == .other("delete failed"))
        await store.refresh()  // a poll tick succeeds…
        #expect(store.lastError == .other("delete failed"))  // …and the action error is still shown
        #expect(store.loadError == nil)
        store.clearError()
        #expect(store.lastError == nil)
    }

    @Test func pollErrorDoesNotOverwriteActionError() async {
        let store = ScriptedStore()
        await store.perform { throw BackendError.other("tag failed") }
        store.refreshFailure = .systemNotRunning
        await store.refresh()
        #expect(store.loadError == .systemNotRunning)
        #expect(store.actionError == .other("tag failed"))
        #expect(store.lastError == .other("tag failed"))
        // Next action clears the old action error; load error stays until a refresh succeeds.
        store.refreshFailure = nil
        #expect(await store.perform {})
        #expect(store.lastError == nil)
    }

    @Test func attemptReturnsTheError() async {
        let store = ScriptedStore()
        let result = await store.attempt { throw BackendError.notFound(kind: "image", id: "x") }
        guard case .failure(let e) = result else { Issue.record("expected failure"); return }
        #expect(e == .notFound(kind: "image", id: "x"))
        #expect(store.actionError == e)
    }

    @Test func settingLastErrorNilClearsBoth() async {
        let store = ScriptedStore()
        store.refreshFailure = .other("df")
        await store.refresh()
        store.lastError = .other("x")
        #expect(store.actionError == .other("x"))
        store.lastError = nil
        #expect(store.loadError == nil && store.actionError == nil)
    }

    @Test func staleLoadResultIsDropped() async {
        let store = ScriptedStore()
        async let slow: Void = store.delayedLoad(1, after: .milliseconds(150))
        try? await Task.sleep(for: .milliseconds(20))
        await store.delayedLoad(2, after: .milliseconds(10))  // newer, finishes first
        await slow
        #expect(store.value == 2)
        #expect(!store.isLoading)
    }

    @Test func performEachRunsEveryIdAndReportsFailures() async {
        let store = ScriptedStore()
        var visited: [String] = []
        let result = await store.performEach(ids: ["a", "b", "c", "d"]) { id in
            visited.append(id)
            if id == "b" || id == "d" { throw BackendError.other("\(id) busy") }
        }
        #expect(visited == ["a", "b", "c", "d"])
        #expect(result.succeeded == ["a", "c"])
        #expect(result.failed.map(\.id) == ["b", "d"])
        #expect(result.summary(verb: "Deleted") == "Deleted 2 of 4")
        let message = store.actionError?.errorDescription ?? ""
        #expect(message.contains("b (b busy)") && message.contains("d (d busy)"))
    }

    @Test func singleFailureKeepsOriginalError() async {
        let store = ScriptedStore()
        let failure = BackendError.commandFailed(command: "container rm x", exitCode: 1, message: "nope")
        _ = await store.performEach(ids: ["x"]) { _ in throw failure }
        #expect(store.actionError == failure)
    }

    @Test func realStoreKeepsConfigValidationErrorAcrossDiskUsagePoll() async {
        let model = TestSupport.model()
        await model.refreshEngine()
        #expect(await model.system.saveConfigTOML("[container\ncpus = 4") == false)
        let shown = model.system.lastError
        #expect(shown != nil)
        await model.system.refreshDiskUsage()  // what the status-bar poller runs
        #expect(model.system.lastError == shown)
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite struct PollerLifecycleTests {
    @Test func quickStopStartNeverRunsTwoTicksAtOnce() async throws {
        let gate = PollingGate(engineRunning: true, appActive: true, interval: .milliseconds(5))
        var concurrent = 0
        var maxConcurrent = 0
        let poller = Poller(gate: gate) {
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            try? await Task.sleep(for: .milliseconds(40))
            concurrent -= 1
        }
        for _ in 0..<5 {
            poller.start()
            try await Task.sleep(for: .milliseconds(10))
            poller.stop()
        }
        poller.start()
        try await Task.sleep(for: .milliseconds(150))
        poller.stopAll()
        #expect(maxConcurrent == 1)
    }

    @Test func backgroundLaneTicksWhileAppInactive() async throws {
        let gate = PollingGate(engineRunning: true, appActive: false, interval: .milliseconds(5))
        var fired = 0
        let poller = Poller(gate: gate, backgroundInterval: .milliseconds(20)) { fired += 1 }
        poller.start()
        #expect(await eventually { fired >= 2 })
        poller.stopAll()
        #expect(poller.currentInterval() == nil)  // no clients left
    }

    @Test func backgroundClientAloneUsesSlowInterval() {
        let gate = PollingGate(engineRunning: true, appActive: true, interval: .seconds(2))
        let poller = Poller(gate: gate, backgroundInterval: .seconds(30)) {}
        poller.startBackground()
        #expect(poller.currentInterval() == .seconds(30))
        poller.start()
        #expect(poller.currentInterval() == .seconds(2))
        gate.appActive = false
        #expect(poller.currentInterval() == .seconds(30))
        gate.engineRunning = false
        #expect(poller.currentInterval() == nil)
        poller.stop()
        #expect(poller.isRunning)  // background client keeps it alive
        poller.stopBackground()
        #expect(!poller.isRunning)
    }

    @Test func pollerWithoutBackgroundLanePausesWhenInactive() {
        let gate = PollingGate(engineRunning: true, appActive: false)
        let poller = Poller(gate: gate) {}
        poller.start()
        #expect(poller.currentInterval() == nil)
        poller.stopAll()
    }

    @Test func pollingSurvivesBackendSwap() async throws {
        let gate = PollingGate(engineRunning: true, interval: .milliseconds(10))
        let switchable = SwitchableBackend(FailingBackend(error: .cliNotInstalled(searchedPaths: [])))
        let mock = MockBackend()
        let containers = ContainersStore(backend: switchable, gate: gate)
        let volumes = VolumesStore(backend: switchable, containers: containers, gate: gate)
        volumes.startPolling()
        #expect(await eventually { volumes.loadError != nil })
        switchable.replace(with: mock)  // what AppModel.replaceBackend does
        #expect(await eventually { !volumes.items.isEmpty })
        #expect(volumes.poller.isRunning)  // same store, same poller, still polling
        #expect(volumes.loadError == nil)
        volumes.stopPolling()
        let model = TestSupport.model()
        #expect(model.storesGeneration == 0)
    }

    @Test func systemDiskUsagePollsEveryTenSeconds() {
        #expect(SystemStore.diskUsageInterval == .seconds(10))
    }

    @Test func bootstrapAddsBackgroundContainersClient() async {
        let model = TestSupport.model()
        await model.bootstrap()
        #expect(model.containers.poller.backgroundInterval == AppModel.backgroundPollInterval)
        #expect(model.containers.poller.backgroundClientCount == 1)
        model.settings.menuBarEnabled = false
        model.settings.notificationsEnabled = false
        #expect(model.containers.poller.backgroundClientCount == 0)
        model.enginePoller.stopAll()
    }
}
