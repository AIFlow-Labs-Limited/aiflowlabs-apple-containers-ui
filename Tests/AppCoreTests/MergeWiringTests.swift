import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

/// Behaviour introduced when the parallel fix branches were stitched together.
@MainActor
@Suite struct MergeWiringTests {
    @Test func buildStoreResolvesPathsAndRecordsTaskID() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let store = BuildsStore(
            backend: MockBackend(), tasks: TaskCenter(), gate: PollingGate(engineRunning: true),
            historyURL: TestSupport.historyURL())
        var spec = BuildSpec(contextDirectory: "~/src/app", tag: "app:dev")
        spec.secrets = ["id=cfg,src=config/secret.txt"]
        let task = store.build(spec)
        let record = try #require(store.history.first)
        let context = (home as NSString).appendingPathComponent("src/app")
        #expect(record.contextDirectory == context)
        #expect(record.taskID == task.id)
        #expect(record.startedAt == task.startedAt)
        await task.wait()
    }

    @Test func buildRecordWithoutTaskIDStillDecodes() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","tag":"t","status":"succeeded"}]"#
        let records = try JSONDecoder().decode([BuildRecord].self, from: Data(json.utf8))
        #expect(records.first?.taskID == nil)
        #expect(records.first?.status == .succeeded)
    }

    @Test func externallyDeletedContainerIsEvictedFromStatsHistory() async throws {
        let backend = MockBackend()
        let store = ContainersStore(backend: backend, gate: PollingGate(engineRunning: true))
        await store.refresh()
        await store.refreshStats()
        #expect(!store.statsHistory.points(for: "db").isEmpty)
        try await backend.deleteContainer("db", force: true)  // removed outside the app
        await store.refresh()
        #expect(store.statsHistory.points(for: "db").isEmpty)
    }

    @Test func bulkSummaryNamesTheResource() {
        #expect(BulkResult(succeeded: ["web"]).summary(verb: "Deleted", noun: "containers") == "Deleted web")
        #expect(
            BulkResult(succeeded: ["a", "b"]).summary(verb: "Deleted", noun: "containers") == "Deleted 2 containers")
        let partial = BulkResult(succeeded: ["a"], failed: [("b", .other("boom"))])
        #expect(partial.summary(verb: "Stopped", noun: "containers") == "Stopped 1 of 2 containers; failed: b (boom)")
    }

    @Test func pruneReturnsItsOwnOutcome() async {
        let gate = PollingGate(engineRunning: true)
        let failing = UnavailableBackend(searchedPaths: [])
        let containers = ContainersStore(backend: failing, gate: gate)
        let volumes = VolumesStore(backend: failing, containers: containers, gate: gate)
        guard case .failure = await volumes.prune() else { Issue.record("expected failure"); return }
        #expect(volumes.actionError != nil)

        let ok = MockBackend()
        let okVolumes = VolumesStore(backend: ok, containers: ContainersStore(backend: ok, gate: gate), gate: gate)
        guard case .success = await okVolumes.prune() else { Issue.record("expected success"); return }
    }

    @Test func runSpecIssuesCoverImageAndBindSource() {
        var spec = RunSpec(image: "-it alpine")
        spec.mounts = [.init(kind: .bind(hostPath: "project"), target: "/src")]
        let issues = spec.issues
        #expect(issues.contains(.invalidImage("-it alpine")))
        #expect(issues.contains(.relativeMountSource("project")))
        var ok = RunSpec(image: " alpine ")
        ok.mounts = [.init(kind: .bind(hostPath: "~/project"), target: "/src")]
        #expect(ok.issues.isEmpty)
        let normalized = ok.normalizedForRun(home: "/Users/me")
        #expect(normalized.image == "alpine")
        guard case .bind(let path) = normalized.mounts.first?.kind else { Issue.record("expected bind"); return }
        #expect(path == "/Users/me/project")
    }
}
