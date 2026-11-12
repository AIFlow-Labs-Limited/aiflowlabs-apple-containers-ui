import ContainerKit
import Foundation
import Testing

@testable import AppCore

/// Compose health-check waits against the real `container` CLI.
///
/// Uses local images only (`redis:7-alpine`, `alpine:latest`). Everything is named `cd-it-…` and removed on
/// every exit path.
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@MainActor
@Suite(
    "Compose Health Integration", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_INTEGRATION"] == "1",
        "set CONTAINER_DESKTOP_INTEGRATION=1 to run against the real CLI"))
struct ComposeHealthIntegrationTests {
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

    private func own(_ prefix: String) async -> [Container] {
        ((try? await backend.listContainers(includeStopped: true)) ?? []).filter { $0.id.hasPrefix(prefix) }
    }

    // MARK: Health checks

    @Test func dependentStartsOnlyAfterARealHealthcheckPasses() async throws {
        let project = uniqueProject()
        // Redis only starts after 4 s, so the first `redis-cli ping` probes fail with "Connection refused".
        let (session, folder) = try await openSession(
            project,
            yaml: """
                name: \(project)
                services:
                  app:
                    image: alpine:latest
                    command: sleep 600
                    restart: unless-stopped
                    depends_on:
                      cache:
                        condition: service_healthy
                  cache:
                    image: redis:7-alpine
                    command: sh -c "sleep 4; exec redis-server"
                    healthcheck:
                      test: ["CMD", "redis-cli", "ping"]
                      interval: 1s
                      timeout: 3s
                      retries: 30
                """)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let plan = try #require(session.plan)
            #expect(plan.problems.isEmpty)
            #expect(
                plan.steps.map(\.id) == ["run:\(project)-cache", "healthy:\(project)-cache", "run:\(project)-app"])
            let run = try await runToEnd(session)
            #expect(run.succeeded, "\(String(describing: run.failure))")

            let output = run.task?.lines.map(\.text) ?? []
            #expect(output.contains { $0.contains("Health check attempt 1 on \(project)-cache: exit code 1") })
            #expect(output.contains { $0.hasPrefix("\(project)-cache is healthy (attempt ") })
            let attempts = Int(run.details["healthy:\(project)-cache"]?.dropFirst("attempt ".count) ?? "") ?? 0
            #expect(attempts >= 3, "only \(attempts) probe(s): the wait did not really wait")

            // Redis answers, and the dependent was started only after that: at least 4 s after the dependency.
            let ping = try await backend.execCapture(
                "\(project)-cache", command: ["redis-cli", "ping"], workingDirectory: nil)
            #expect(ping.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "PONG")
            let cache = try await backend.inspectContainer("\(project)-cache")
            let app = try await backend.inspectContainer("\(project)-app")
            let gap = try #require(app.status?.startedDate).timeIntervalSince(try #require(cache.status?.startedDate))
            #expect(gap >= 4, "app started \(gap) s after cache")
            #expect(app.isRunning)
            // The restart policy is on the container as a label, where the supervisor reads it.
            #expect(app.labels[AppLabel.restart] == "unless-stopped")
            #expect(app.restartPolicy == .unlessStopped)
            #expect(cache.labels[AppLabel.restart] == nil)
        } catch {
            await removeContainers(prefix: project)
            throw error
        }
        await removeContainers(prefix: project)
    }

    @Test func aDependencyThatNeverBecomesHealthyStopsTheRun() async throws {
        let project = uniqueProject()
        let (session, folder) = try await openSession(
            project,
            yaml: """
                name: \(project)
                services:
                  app:
                    image: alpine:latest
                    command: sleep 600
                    depends_on:
                      db: {condition: service_healthy}
                  db:
                    image: alpine:latest
                    command: sleep 600
                    healthcheck:
                      test: ["CMD-SHELL", "echo not ready >&2; exit 3"]
                      interval: 500ms
                      timeout: 2s
                      retries: 2
                """)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let run = try await runToEnd(session)
            #expect(!run.succeeded)
            let failure = try #require(run.failure)
            #expect(failure.step.id == "healthy:\(project)-db")
            guard case .commandFailed(let command, let exitCode, let message) = failure.error else {
                Issue.record("unexpected error \(failure.error)")
                throw failure.error
            }
            #expect(command == "container exec -- \(project)-db /bin/sh -c 'echo not ready >&2; exit 3'")
            #expect(exitCode == 3)
            #expect(
                message
                    == "\(project)-db did not become healthy: its health check failed 2 times in a row (last "
                    + "result: exit code 3: not ready).")
            // The dependent was never started; the dependency is left in place and can be removed from the sheet.
            let names = await own(project).map(\.id)
            #expect(names == ["\(project)-db"])
            #expect(run.created.containers == ["\(project)-db"])
            #expect(await run.removeCreated(backend: backend).isEmpty)
            #expect(await own(project).isEmpty)
        } catch {
            await removeContainers(prefix: project)
            throw error
        }
        await removeContainers(prefix: project)
    }

    @Test func completedDependencyIsWaitedForAndItsExitCodeIsNotReported() async throws {
        let project = uniqueProject()
        let (session, folder) = try await openSession(
            project,
            yaml: """
                name: \(project)
                services:
                  app:
                    image: alpine:latest
                    command: sleep 600
                    depends_on:
                      job: {condition: service_completed_successfully}
                  job:
                    image: alpine:latest
                    command: sh -c "sleep 3; exit 7"
                """)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let run = try await runToEnd(session)
            #expect(run.succeeded, "\(String(describing: run.failure))")
            let job = try await backend.inspectContainer("\(project)-job")
            let app = try await backend.inspectContainer("\(project)-app")
            #expect(!job.isRunning)
            #expect(app.isRunning)
            let gap = try #require(app.status?.startedDate).timeIntervalSince(try #require(job.status?.startedDate))
            #expect(gap >= 3, "app started \(gap) s after the job")
            // What the 1.5.0 runtime says about a container that exited with code 7: a state, no exit code.
            let raw = try await ProcessRunner().run(
                [backend.executable, "inspect", "\(project)-job"], timeout: .seconds(30))
            let text = raw.stdoutText
            #expect(text.contains("\"stopped\""))
            #expect(!text.lowercased().contains("exitcode"))
            #expect(!text.lowercased().contains("exit_code"))
        } catch {
            await removeContainers(prefix: project)
            throw error
        }
        await removeContainers(prefix: project)
    }
}
