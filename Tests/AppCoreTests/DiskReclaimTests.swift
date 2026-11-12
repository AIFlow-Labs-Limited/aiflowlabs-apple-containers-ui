import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

/// "Reclaim Disk Space" (`container clean`) as an Activity task.
@MainActor
@Suite struct DiskReclaimTests {
    private func lines(_ stream: LineStream) async -> (text: [String], error: BackendError?) {
        var text: [String] = []
        do {
            for try await line in stream { text.append(line.text) }
            return (text, nil)
        } catch {
            return (text, BackendError(wrapping: error))
        }
    }

    @Test func onlyRunningContainersAreEligible() async throws {
        let backend = MockBackend(kubernetes: .modern)
        let all = try await backend.listContainers(includeStopped: true)
        let running = all.filter(\.isRunning).map(\.id)
        #expect(!running.isEmpty && running.count < all.count, "the fixtures have running and stopped containers")
        #expect(DiskReclaim.eligible(all) == running)
        #expect(DiskReclaim.title(for: ["web"]) == "Reclaim disk space of web")
        #expect(DiskReclaim.title(for: ["web", "db"]) == "Reclaim disk space of 2 containers")
    }

    @Test func outputStartsWithTheCommandAndEndsWithWhatHappened() async throws {
        let backend = MockBackend(kubernetes: .modern)
        let id = try #require(try await backend.listContainers(includeStopped: false).first?.id)
        let result = await lines(DiskReclaim.stream(ids: [id], backend: backend))
        #expect(result.error == nil)
        #expect(
            result.text == [
                "$ container clean -- \(id)", id,
                "Unused space in \(id) was given back to the Mac. Nothing inside was deleted.",
            ])
    }

    @Test func runsAsAnActivityTaskAndLeavesTheContainersAlone() async throws {
        let backend = MockBackend(kubernetes: .modern)
        let model = TestSupport.model(backend)
        await model.containers.refresh()
        let before = model.containers.items
        var finished: LongRunningTask.State?
        let task = try #require(
            DiskReclaim.run(before, backend: model.backend, taskCenter: model.taskCenter) { finished = $0 })
        await task.wait()
        #expect(task.state == .succeeded)
        #expect(finished == .succeeded)
        #expect(task.title == DiskReclaim.title(for: DiskReclaim.eligible(before)))
        #expect(task.lines.first?.text.hasPrefix("$ container clean -- ") == true)
        #expect(await backend.cleanedContainers == DiskReclaim.eligible(before))
        await model.containers.refresh()
        #expect(model.containers.items.map(\.id) == before.map(\.id))
        #expect(model.containers.items.map(\.isRunning) == before.map(\.isRunning))

        let stopped = before.filter { !$0.isRunning }
        #expect(DiskReclaim.run(stopped, backend: model.backend, taskCenter: model.taskCenter) == nil)
    }

    @Test func aRuntimeWithoutCleanFailsTheTaskWithTheReason() async throws {
        let backend = MockBackend(kubernetes: .legacy)
        #expect(await !backend.supportsClean())
        let model = TestSupport.model(backend)
        #expect(await !model.backend.supportsClean())  // through the switchable wrapper
        let running = try await backend.listContainers(includeStopped: false)
        let task = try #require(DiskReclaim.run(running, backend: model.backend, taskCenter: model.taskCenter))
        await task.wait()
        guard case .failed(.unsupported(let feature, _)) = task.state else {
            Issue.record("expected an unsupported failure, got \(task.state)")
            return
        }
        #expect(feature == "Reclaim Disk Space")
        #expect(await !UnavailableBackend(searchedPaths: []).supportsClean())
    }
}
