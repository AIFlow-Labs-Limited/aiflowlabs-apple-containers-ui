import ContainerKit
import ContainerKitMock
import Foundation
import Synchronization
import Testing

@testable import AppCore

/// `depends_on` conditions: the plan's wait steps and how a run performs them — against `MockBackend` only.
@MainActor
@Suite("Compose dependency waits")
struct ComposeWaitTests {
    /// `web` waits for `db` to be healthy; timings short enough for a test.
    private let healthy = """
        name: waits
        services:
          web:
            image: docker.io/library/postgres:16-alpine
            depends_on:
              db: {condition: service_healthy}
            restart: unless-stopped
          db:
            image: docker.io/library/postgres:16-alpine
            restart: on-failure:3
            healthcheck:
              test: ["CMD", "pg_isready"]
              interval: 20ms
              timeout: 2s
              retries: 3
        """

    /// Plans with every image already local, so the steps are only runs and waits.
    private func plan(_ yaml: String) throws -> ComposePlan {
        var environment = ComposeEnvironment()
        environment.isLoaded = true
        environment.images = ["docker.io/library/x:latest", "docker.io/library/postgres:16-alpine"]
        return ComposeSamples.plan(try ComposeSamples.inline(yaml), environment: environment)
    }

    /// Runs `plan` on a mock whose exec results come from `exec`.
    private func run(
        _ plan: ComposePlan, exec: MockBackend.ExecHandler?, prepare: ((MockBackend) async throws -> Void)? = nil
    ) async throws -> (ComposeRun, MockBackend) {
        let backend = MockBackend()
        await backend.setLatency(.zero)
        await backend.setExecHandler(exec)
        try await prepare?(backend)
        let run = ComposeRun(plan: plan)
        await run.start(backend: backend, taskCenter: TaskCenter()).wait()
        return (run, backend)
    }

    // MARK: Planning

    @Test func healthyDependencyBecomesAWaitStepBeforeTheDependent() throws {
        let plan = try plan(healthy)
        #expect(plan.problems.isEmpty)
        #expect(plan.steps.map(\.id) == ["run:db", "healthy:db", "run:web"])
        let wait = plan.steps[1]
        #expect(wait.title == "Wait for db to be healthy")
        #expect(wait.isWait)
        #expect(wait.service == "db")
        #expect(wait.commandLine() == "until container exec -- db pg_isready; do sleep 0.02; done")
        // The preview shows the check, the wait and the restart policy per service.
        let db = try #require(plan.services.first { $0.name == "db" })
        let web = try #require(plan.services.first { $0.name == "web" })
        #expect(db.healthcheck?.command == ["pg_isready"])
        #expect(db.restart == .onFailure(maxRetries: 3))
        #expect(web.waitsFor == ["db to be healthy"])
        #expect(web.restart == .unlessStopped)
        // Restart policies travel as a label on the container.
        #expect(plan.runSpec("db")?.labels[AppLabel.restart] == "on-failure:3")
        #expect(plan.runSpec("web")?.labels[AppLabel.restart] == "unless-stopped")
        #expect(plan.runSpec("web")?.cliArguments.contains("\(AppLabel.restart)=unless-stopped") == true)
        // No "ignored" warning any more; a note says health is checked during the import only.
        #expect(!plan.warnings.contains { $0.severity == .unsupported })
        let note = try #require(plan.warnings.first { $0.scope == .service("db") && $0.key == "healthcheck" })
        #expect(note.message.contains("during the import"))
        #expect(note.message.contains("not run afterwards"))
    }

    @Test func healthyWithoutAHealthcheckBlocksThePlan() throws {
        for healthcheck in ["", "    healthcheck: {disable: true}\n", "    healthcheck: {interval: 5s}\n"] {
            let plan = try plan(
                "services:\n  web: {image: x, depends_on: {db: {condition: service_healthy}}}\n  db:\n    image: x\n"
                    + healthcheck)
            #expect(!plan.canRun)
            #expect(plan.problems.contains { $0.service == "web" && $0.message.contains("has no health check") })
            #expect(!plan.steps.contains { $0.isWait })
        }
    }

    @Test func oneWaitPerDependencyAndNoWaitWithoutACondition() throws {
        let plan = try plan(
            """
            services:
              a: {image: x, depends_on: {db: {condition: service_healthy}}}
              b: {image: x, depends_on: {db: {condition: service_healthy}, a: {condition: service_started}}}
              c: {image: x, depends_on: [db]}
              db: {image: x, healthcheck: {test: "true"}}
              lonely: {image: x, healthcheck: {test: "true"}}
            """)
        #expect(plan.steps.map(\.id) == ["run:db", "healthy:db", "run:a", "run:b", "run:c", "run:lonely"])
        let lonely = try #require(plan.warnings.first { $0.scope == .service("lonely") })
        #expect(lonely.message.contains("No service waits for this health check"))
    }

    @Test func completedDependencyWaitsForTheContainerToStop() throws {
        let plan = try plan(
            """
            services:
              app: {image: x, depends_on: {migrate: {condition: service_completed_successfully}}}
              migrate: {image: x, container_name: shop-migrate}
            """)
        #expect(plan.steps.map(\.id) == ["run:shop-migrate", "completed:shop-migrate", "run:app"])
        #expect(plan.steps[1].title == "Wait for shop-migrate to finish")
        #expect(
            plan.steps[1].commandLine()
                == "while container list --quiet | grep -qx shop-migrate; do sleep 1; done")
        #expect(plan.services.first { $0.name == "app" }?.waitsFor == ["shop-migrate to finish"])
        // The runtime reports no exit code, and the plan says what that means.
        let note = try #require(plan.warnings.first { $0.key == "depends_on.migrate.condition" })
        #expect(note.severity == .note)
        #expect(note.message.contains("does not report exit codes"))
    }

    // MARK: Running

    @Test func dependentStartsOnlyAfterTheCheckPasses() async throws {
        let attempts = Mutex(0)
        let startedWhenHealthy = Mutex<[String]>([])
        let backend = MockBackend()
        await backend.setLatency(.zero)
        await backend.setExecHandler { id, command in
            #expect(id == "db")
            #expect(command == ["pg_isready"])
            let attempt = attempts.withLock {
                $0 += 1; return $0
            }
            if attempt < 3 { return (1, "", "no response\n") }
            // What exists at the moment the check passes: the dependent must not be there yet.
            let names = await backend.containers.map(\.id)
            startedWhenHealthy.withLock { $0 = names }
            return (0, "accepting connections\n", "")
        }
        let run = ComposeRun(plan: try plan(healthy))
        await run.start(backend: backend, taskCenter: TaskCenter()).wait()

        #expect(run.succeeded)
        #expect(attempts.withLock { $0 } == 3)
        #expect(startedWhenHealthy.withLock { $0 }.contains("db"))
        #expect(!startedWhenHealthy.withLock { $0 }.contains("web"))
        #expect(await backend.containers.contains { $0.id == "web" })
        #expect(run.details["healthy:db"] == "attempt 3")
        let output = run.task?.lines.map(\.text) ?? []
        #expect(output.contains("Health check attempt 2 on db: exit code 1: no response"))
        #expect(output.contains("db is healthy (attempt 3)."))
    }

    @Test func liveStatusNamesTheAttempt() throws {
        let plan = try plan(healthy)
        let run = ComposeRun(plan: plan)
        #expect(run.liveStatus(of: plan.steps[1]) == nil)  // not running yet
    }

    @Test func unhealthyAfterTheRetriesStopsTheRun() async throws {
        let attempts = Mutex(0)
        let (run, backend) = try await run(try plan(healthy)) { _, _ in
            attempts.withLock { $0 += 1 }
            return (2, "", "connection refused\n")
        }
        #expect(!run.succeeded)
        // The immediate first probe is free, then `retries` (3) counted failures.
        #expect(attempts.withLock { $0 } == 4)
        let failure = try #require(run.failure)
        #expect(failure.step.id == "healthy:db")
        #expect(
            failure.error
                == .commandFailed(
                    command: "container exec -- db pg_isready", exitCode: 2,
                    message: "db did not become healthy: its health check failed 3 times in a row (last result: "
                        + "exit code 2: connection refused)."))
        #expect(run.state(of: run.plan.steps[0]) == .succeeded)
        #expect(run.state(of: run.plan.steps[2]) == .skipped)
        #expect(!(await backend.containers.contains { $0.id == "web" }))
        #expect(run.created.containers == ["db"])  // left in place, removable from the sheet
    }

    @Test func failuresDuringTheStartPeriodDoNotCount() async throws {
        // One retry, a long interval: without the start period the second probe would end the run, and with the
        // normal interval between probes the test would take minutes.
        let yaml = healthy.replacingOccurrences(of: "interval: 20ms", with: "interval: 60s")
            .replacingOccurrences(
                of: "retries: 3", with: "retries: 1\n      start_period: 30s\n      start_interval: 10ms")
        let attempts = Mutex(0)
        let (run, _) = try await run(try plan(yaml)) { _, _ in
            attempts.withLock {
                $0 += 1; return $0
            } < 5 ? (1, "", "starting") : (0, "", "")
        }
        #expect(run.succeeded)
        #expect(run.details["healthy:db"] == "attempt 5")
        #expect((run.task?.duration ?? 99) < 10)
    }

    @Test func aProbeThatHangsTimesOut() async throws {
        let yaml = healthy.replacingOccurrences(of: "timeout: 2s", with: "timeout: 30ms")
            .replacingOccurrences(of: "retries: 3", with: "retries: 1")
        let (run, _) = try await run(try plan(yaml)) { _, _ in
            try? await Task.sleep(for: .seconds(20))
            return (0, "", "")
        }
        let failure = try #require(run.failure)
        #expect(failure.error.errorDescription?.contains("no answer within the timeout") == true)
        #expect((run.task?.duration ?? 99) < 5)
    }

    @Test func aDependencyThatStopsWhileWaitedForFailsAtOnce() async throws {
        let backend = MockBackend()
        await backend.setLatency(.zero)
        await backend.setExecHandler { id, _ in
            try? await backend.simulateExit(id)
            return (1, "", "")
        }
        let run = ComposeRun(plan: try plan(healthy))
        await run.start(backend: backend, taskCenter: TaskCenter()).wait()
        let failure = try #require(run.failure)
        #expect(failure.error == .other("db stopped before it became healthy. Look at its logs (`container logs db`)."))
    }

    @Test func cancellingTheRunCancelsTheWait() async throws {
        let yaml = healthy.replacingOccurrences(of: "interval: 20ms", with: "interval: 30s")
        let backend = MockBackend()
        await backend.setLatency(.zero)
        await backend.setExecHandler { _, _ in (1, "", "") }
        let run = ComposeRun(plan: try plan(yaml))
        let task = run.start(backend: backend, taskCenter: TaskCenter())
        for _ in 0..<200 where run.details["healthy:db"] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(run.liveStatus(of: run.plan.steps[1]) == "Waiting for db to be healthy (attempt 1)")
        task.cancel()
        await task.wait()
        #expect(run.wasCancelled)
        #expect(run.failure == nil)
        #expect(run.state(of: run.plan.steps[1]) == .skipped)
        #expect(run.state(of: run.plan.steps[2]) == .skipped)
        #expect((task.duration) < 5)
    }

    @Test func completedWaitEndsWhenTheContainerHasStopped() async throws {
        let plan = try plan(
            """
            services:
              app: {image: docker.io/library/postgres:16-alpine, depends_on: {job: {condition: service_completed_successfully}}}
              job: {image: docker.io/library/postgres:16-alpine}
            """)
        let backend = MockBackend()
        await backend.setLatency(.zero)
        let run = ComposeRun(plan: plan)
        let task = run.start(backend: backend, taskCenter: TaskCenter())
        for _ in 0..<200 where run.details["completed:job"] == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(run.liveStatus(of: plan.steps[1]) == "Waiting for job to finish (0 s)")
        #expect(!(await backend.containers.contains { $0.id == "app" }))
        try await backend.simulateExit("job")
        await task.wait()
        #expect(run.succeeded)
        #expect(await backend.containers.contains { $0.id == "app" })
    }
}
