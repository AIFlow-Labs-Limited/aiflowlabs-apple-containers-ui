import ContainerKit
import Foundation
import Testing

@testable import AppCore

/// The background helper against the real `container` CLI.
///
/// Uses the local `alpine:latest` only. Everything is named `cd-it-…` and removed on every exit path, and the
/// helper built here is scoped to `cd-it-` containers, so nothing else on the engine can be started.
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
///
/// The two tests need opposite set-ups, so one of them is always left out:
///
/// * `theHelperLoop…` runs its own helper in this process and needs the installed one switched off (two helpers
///   on different state files would both restart the container).
/// * `theRegisteredHelper…` talks to the helper that macOS runs (Settings › General › "Keep enforcing when
///   Container Desktop is closed", or `ContainerDesktop --background-supervision register`). It needs that
///   helper running and is skipped unless `CONTAINER_DESKTOP_HELPER_LIVE=1` is set as well.
@MainActor
@Suite(
    "Background Helper Integration", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_INTEGRATION"] == "1",
        "set CONTAINER_DESKTOP_INTEGRATION=1 to run against the real CLI"))
struct BackgroundSupervisorIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    private func uniquePrefix() -> String { "cd-it-\(UUID().uuidString.prefix(8).lowercased())" }

    private func removeContainers(prefix: String) async {
        precondition(prefix.hasPrefix("cd-it-"))
        for container in (try? await backend.listContainers(includeStopped: true)) ?? []
        where container.id.hasPrefix(prefix) {
            try? await backend.deleteContainer(container.id, force: true)
        }
    }

    private func runDetached(_ name: String, policy: String) async throws {
        var spec = RunSpec(image: "alpine:latest")
        spec.name = name
        spec.command = ["sleep", "600"]
        spec.labels = [AppLabel.restart: policy]
        for try await _ in backend.runContainer(spec) {}
    }

    private func container(_ name: String) async -> Container? {
        try? await backend.inspectContainer(name)
    }

    /// Waits until `name` runs with a start date after `after` (it was started again). Calls `pass` between looks.
    private func waitForRestart(
        of name: String, after: Date, seconds: Int, pass: () async -> Void = {}
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            await pass()
            if let now = await container(name), now.isRunning, let started = now.status?.startedDate, started > after {
                return true
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_HELPER_LIVE"] != "1",
            "runs its own helper; not together with the installed one (CONTAINER_DESKTOP_HELPER_LIVE=1)"))
    func theHelperLoopRestartsAStoppedContainerAndRespectsAStopFromTheApp() async throws {
        try #require(
            !TestSupport.backgroundHelperIsRunning,
            "the background helper is running and would restart this container too: switch it off first")
        let prefix = uniquePrefix()
        let name = "\(prefix)-svc"
        let paths = SupervisionPaths(
            directory: FileManager.default.temporaryDirectory.appending(path: "\(prefix)-supervision"))
        let helper = BackgroundSupervisor(
            backend: backend, state: FileSupervisionState(url: paths.state),
            claim: EnforcementClaim(role: .helper, paths: paths), scope: { $0.id.hasPrefix(prefix) })
        // The app's side: it stands down for the helper and only records what the user does.
        let appClaim = EnforcementClaim(role: .app, paths: paths)
        let backend = backend
        let app = RestartSupervisor(state: FileSupervisionState(url: paths.state), claim: { appClaim.hold() }) { id in
            precondition(id.hasPrefix("cd-it-"))
            try await backend.startContainer(id)
        }
        do {
            try await runDetached(name, policy: "always")
            _ = await helper.step()
            #expect(helper.phase == .supervising(policies: 1))
            #expect(!appClaim.hold(), "the app must stand down while a helper is alive")
            let firstStart = try #require(await container(name)?.status?.startedDate)

            // Stopped behind the helper's back, as by `container stop` in a terminal or a crash.
            try await backend.killContainer(name, signal: nil)
            let restarted = try await waitForRestart(of: name, after: firstStart, seconds: 30) {
                _ = await helper.step()
            }
            #expect(restarted, "the helper did not start \(name) again within 30 s")
            #expect(helper.restarts.status(for: name)?.restartCount == 1)

            // Stopped the way the app does it: intent recorded in the shared state, then the stop.
            app.noteStopRequested([name])
            try await backend.killContainer(name, signal: nil)
            for _ in 0..<12 {
                _ = await helper.step()
                try await Task.sleep(for: .milliseconds(500))
            }
            #expect(await container(name)?.isRunning == false)
            #expect(helper.restarts.status(for: name)?.restartCount == 1)
        } catch {
            await removeContainers(prefix: prefix)
            try? FileManager.default.removeItem(at: paths.directory)
            throw error
        }
        await removeContainers(prefix: prefix)
        try? FileManager.default.removeItem(at: paths.directory)
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_HELPER_LIVE"] == "1",
            "set CONTAINER_DESKTOP_HELPER_LIVE=1 with the background helper registered and the app closed"))
    func theRegisteredHelperRestartsAndRespectsAStopFromTheApp() async throws {
        // Without a live helper this process would become the enforcer for every container on the engine.
        try #require(TestSupport.backgroundHelperIsRunning, "the background helper is not running: register it first")
        let prefix = uniquePrefix()
        let name = "\(prefix)-live"
        // The app's own wiring: the standard state file and the app's claim, which yields to the helper.
        let model = AppModel(
            backend: backend, settings: SettingsStore(defaults: TestSupport.defaults()),
            buildsHistoryURL: TestSupport.historyURL(), observeAppActivation: false,
            supervision: .app(adopting: TestSupport.defaults()))
        do {
            try await runDetached(name, policy: "always")
            let firstStart = try #require(await container(name)?.status?.startedDate)
            // Give the helper one pass to see it running (10 s between passes, 30 s when it had nothing to watch).
            try await Task.sleep(for: .seconds(32))

            try await backend.killContainer(name, signal: nil)
            #expect(
                try await waitForRestart(of: name, after: firstStart, seconds: 45),
                "the registered helper did not start \(name) again within 45 s")

            // Stop in the app (the Containers store): the helper must leave it stopped.
            await model.containers.refresh()
            let result = await model.containers.stop([name], timeoutSeconds: 1)
            #expect(result.failed.isEmpty)
            #expect(model.restarts.isIntentionallyStopped(name))
            try await Task.sleep(for: .seconds(35))
            #expect(await container(name)?.isRunning == false, "the helper undid a stop made in the app")
        } catch {
            await removeContainers(prefix: prefix)
            throw error
        }
        await removeContainers(prefix: prefix)
    }
}
