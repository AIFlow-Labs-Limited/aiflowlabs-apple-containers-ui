import ContainerKit
import Foundation
import Testing

@testable import AppCore

/// Restart policies against the real `container` CLI: containers that really exit, really get started again.
///
/// Uses the local `alpine:latest` only. Everything is named `cd-it-…` and removed on every exit path. The
/// supervisor is only ever shown containers whose name starts with `cd-it-`, so nothing else on the engine can
/// be started by these tests (the one test that uses the app's own supervisor checks first that it is safe).
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@MainActor
@Suite(
    "Restart Policy Integration", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_INTEGRATION"] == "1",
        "set CONTAINER_DESKTOP_INTEGRATION=1 to run against the real CLI"))
struct RestartPolicyIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    // MARK: Helpers

    private func uniqueProject() -> String { "cd-it-\(UUID().uuidString.prefix(8).lowercased())" }

    private func openSession(_ project: String, yaml: String) async throws -> (ComposeImport, URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(project) compose")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(yaml.utf8).write(to: folder.appending(path: "compose.yaml"))
        let session = ComposeImport()
        session.open(folder.appending(path: "compose.yaml"))
        session.options.naming = .projectPrefixed
        await session.refreshEnvironment(backend: backend)
        return (session, folder)
    }

    private func runToEnd(_ session: ComposeImport) async throws -> ComposeRun {
        let run = try #require(session.start(backend: backend, taskCenter: TaskCenter()))
        let deadline = ContinuousClock.now + .seconds(180)
        while !run.isFinished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(run.isFinished, "the run did not finish in time")
        return run
    }

    /// Force-deletes every container whose name starts with `prefix` (always `cd-it-…`). Never throws.
    private func removeContainers(prefix: String) async {
        precondition(prefix.hasPrefix("cd-it-"))
        for container in (try? await backend.listContainers(includeStopped: true)) ?? []
        where container.id.hasPrefix(prefix) {
            try? await backend.deleteContainer(container.id, force: true)
        }
    }

    /// The test's own containers, which is all the supervisor ever gets to see.
    private func own(_ prefix: String) async -> [Container] {
        ((try? await backend.listContainers(includeStopped: true)) ?? []).filter { $0.id.hasPrefix(prefix) }
    }

    private func runDetached(_ name: String, policy: String, script: String) async throws {
        var spec = RunSpec(image: "alpine:latest")
        spec.name = name
        spec.command = ["sh", "-c", script]
        spec.labels = [AppLabel.restart: policy]
        for try await _ in backend.runContainer(spec) {}
    }

    /// A supervisor on the real clock that starts containers through the real backend and logs each start.
    private func makeSupervisor(defaults: UserDefaults, log: StartLog) -> RestartSupervisor {
        let backend = backend
        return RestartSupervisor(defaults: defaults) { id in
            precondition(id.hasPrefix("cd-it-"))
            log.record(id)
            try await backend.startContainer(id)
        }
    }

    /// Polls like the app does (every 500 ms) until `done` or `seconds` have passed.
    private func poll(
        _ supervisor: RestartSupervisor, prefix: String, for seconds: Int, until done: () -> Bool = { false }
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline, !done() {
            await supervisor.observe(await own(prefix))
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    // MARK: Tests

    @Test func alwaysIsRestartedWithGrowingDelays() async throws {
        let prefix = uniqueProject()
        let name = "\(prefix)-crashy"
        let log = StartLog()
        let supervisor = makeSupervisor(defaults: TestSupport.defaults(), log: log)
        do {
            try await runDetached(name, policy: "always", script: "sleep 2; exit 1")
            try await poll(supervisor, prefix: prefix, for: 60) { log.times.count >= 3 }
            let times = log.times
            #expect(times.count >= 3, "restarted \(times.count) time(s) in 60 s")
            #expect(log.ids.allSatisfy { $0 == name })
            if times.count >= 3 {
                // Each cycle is "run 2 s, wait, start"; the wait doubles (1 s, 2 s, 4 s), so cycles get longer.
                let second = times[1].timeIntervalSince(times[0])
                let third = times[2].timeIntervalSince(times[1])
                #expect(third > second + 1, "cycles of \(second) s and \(third) s")
            }
            #expect(supervisor.status(for: name)?.restartCount == times.count)
            #expect((supervisor.status(for: name)?.consecutiveAttempts ?? 0) >= 3)
        } catch {
            await removeContainers(prefix: prefix)
            throw error
        }
        await removeContainers(prefix: prefix)
    }

    @Test func aStopFromTheAppStaysDownAndLaunchBringsAlwaysBack() async throws {
        let prefix = uniqueProject()
        let always = "\(prefix)-always"
        let unless = "\(prefix)-unless"
        let defaults = TestSupport.defaults()
        let log = StartLog()
        let supervisor = makeSupervisor(defaults: defaults, log: log)
        do {
            try await runDetached(always, policy: "always", script: "sleep 600")
            try await runDetached(unless, policy: "unless-stopped", script: "sleep 600")
            try await poll(supervisor, prefix: prefix, for: 2)
            // What the app does on Stop: tell the supervisor, then stop the container.
            supervisor.noteStopRequested([always, unless])
            try await backend.killContainer(always, signal: nil)
            try await backend.killContainer(unless, signal: nil)
            try await poll(supervisor, prefix: prefix, for: 8)
            #expect(log.ids.isEmpty, "restarted \(log.ids) although both were stopped from the app")
            #expect(await own(prefix).allSatisfy { !$0.isRunning })

            // The app is launched again: `always` comes back, `unless-stopped` stays stopped.
            let relaunched = makeSupervisor(defaults: defaults, log: log)
            try await poll(relaunched, prefix: prefix, for: 6)
            #expect(log.ids == [always])
            #expect(try await backend.inspectContainer(always).isRunning)
            #expect(!(try await backend.inspectContainer(unless).isRunning))
        } catch {
            await removeContainers(prefix: prefix)
            throw error
        }
        await removeContainers(prefix: prefix)
    }

    @Test func onFailureStopsAfterTwoAttempts() async throws {
        let prefix = uniqueProject()
        let name = "\(prefix)-flaky"
        let log = StartLog()
        let supervisor = makeSupervisor(defaults: TestSupport.defaults(), log: log)
        var gaveUp: [Int] = []
        supervisor.onGiveUp = { _, attempts in gaveUp.append(attempts) }
        do {
            try await runDetached(name, policy: "on-failure:2", script: "sleep 1; exit 1")
            try await poll(supervisor, prefix: prefix, for: 60) { supervisor.status(for: name)?.gaveUp == true }
            #expect(supervisor.status(for: name)?.gaveUp == true)
            // Nothing more happens afterwards.
            try await poll(supervisor, prefix: prefix, for: 8)
            #expect(log.ids == [name, name])
            #expect(gaveUp == [2])
            #expect(supervisor.status(for: name)?.restartCount == 2)
            #expect(!(try await backend.inspectContainer(name).isRunning))
        } catch {
            await removeContainers(prefix: prefix)
            throw error
        }
        await removeContainers(prefix: prefix)
    }

    /// The whole path the app takes: compose `restart:` → label → containers poll → supervisor → Activity entry,
    /// and Stop in the Containers list keeping it down.
    @Test func theAppRestartsACrashedComposeServiceAndRespectsStop() async throws {
        // This test lets the app's own supervisor see the whole engine, so it only runs when nothing but this
        // suite's containers carries a restart policy: nothing of the owner's can be started by it.
        let foreign = ((try? await backend.listContainers(includeStopped: true)) ?? [])
            .filter { !$0.id.hasPrefix("cd-it-") && $0.restartPolicy.isEnforced }
        guard foreign.isEmpty else {
            Issue.record("skipped: \(foreign.map(\.id)) carry a restart policy on this engine")
            return
        }
        let project = uniqueProject()
        let name = "\(project)-web"
        let (session, folder) = try await openSession(
            project,
            yaml: """
                name: \(project)
                services:
                  web:
                    image: alpine:latest
                    command: sh -c "sleep 3; exit 1"
                    restart: always
                """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(
            backend: backend, settings: SettingsStore(defaults: TestSupport.defaults()),
            buildsHistoryURL: TestSupport.historyURL(), observeAppActivation: false)
        func pollApp(for seconds: Int, until done: () -> Bool = { false }) async throws {
            let deadline = ContinuousClock.now + .seconds(seconds)
            while ContinuousClock.now < deadline, !done() {
                await model.containers.poller.fireNow()
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        do {
            await model.containers.poller.fireNow()  // the launch look, before the project exists
            let run = try await runToEnd(session)
            #expect(run.succeeded, "\(String(describing: run.failure))")
            try await pollApp(for: 40) { (model.restarts.status(for: name)?.restartCount ?? 0) >= 2 }
            #expect((model.restarts.status(for: name)?.restartCount ?? 0) >= 2)
            #expect(model.taskCenter.tasks.contains { $0.title == "Restart \(name), attempt 1" })
            #expect(model.taskCenter.tasks.contains { $0.title == "Restart \(name), attempt 2" })

            // Stop in the app while it is up: it stays down.
            try await pollApp(for: 30) { model.containers.container(id: name)?.isRunning == true }
            let countAtStop = model.restarts.status(for: name)?.restartCount ?? 0
            await model.containers.stop([name], timeoutSeconds: 1)
            #expect(model.restarts.isIntentionallyStopped(name))
            try await pollApp(for: 8)
            #expect(model.restarts.status(for: name)?.restartCount == countAtStop)
            #expect(model.containers.container(id: name)?.isRunning == false)
        } catch {
            await removeContainers(prefix: project)
            throw error
        }
        await removeContainers(prefix: project)
    }

    @Test func aContainerWithoutAPolicyIsLeftAlone() async throws {
        let prefix = uniqueProject()
        let name = "\(prefix)-plain"
        let log = StartLog()
        let supervisor = makeSupervisor(defaults: TestSupport.defaults(), log: log)
        do {
            var spec = RunSpec(image: "alpine:latest")
            spec.name = name
            spec.command = ["sh", "-c", "sleep 1; exit 1"]
            for try await _ in backend.runContainer(spec) {}
            try await poll(supervisor, prefix: prefix, for: 8)
            #expect(log.ids.isEmpty)
            #expect(!(try await backend.inspectContainer(name).isRunning))
        } catch {
            await removeContainers(prefix: prefix)
            throw error
        }
        await removeContainers(prefix: prefix)
    }
}

/// When the supervisor asked for which container to be started.
@MainActor
final class StartLog {
    private(set) var ids: [String] = []
    private(set) var times: [Date] = []
    func record(_ id: String) {
        ids.append(id)
        times.append(Date())
    }
}
