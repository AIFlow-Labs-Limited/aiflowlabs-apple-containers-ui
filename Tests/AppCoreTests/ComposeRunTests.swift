import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

/// Loading, the import session and execution — all against `MockBackend`, never the real runtime.
@MainActor
@Suite("Compose import and run")
struct ComposeRunTests {
    /// A temporary project folder with `compose.yaml` and optional extra files.
    private func folder(_ yaml: String, files: [String: String] = [:]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cd-compose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(yaml.utf8).write(to: folder.appending(path: "compose.yaml"))
        for (name, text) in files { try Data(text.utf8).write(to: folder.appending(path: name)) }
        return folder
    }

    private let small = """
        name: tiny
        services:
          app:
            image: docker.io/library/postgres:16-alpine
            volumes: ["data:/data"]
            depends_on: [helper]
          helper:
            image: docker.io/library/postgres:16-alpine
        volumes:
          data:
        """

    @Test func loaderReadsDotEnvAndFindsFilesInFolders() throws {
        let dotEnv = try ComposeSamples.text("interpolation/dot.env")
        let folder = try folder(
            try ComposeSamples.text("interpolation/compose.yaml"),
            files: [".env": dotEnv, "compose.override.yaml": "services: {}\n"])
        defer { try? FileManager.default.removeItem(at: folder) }

        // A dropped folder resolves to its compose file; other files are not candidates.
        let url = try #require(ComposeLoader.composeFile(at: folder))
        #expect(url.lastPathComponent == "compose.yaml")
        #expect(ComposeLoader.composeFile(at: folder.appending(path: ".env")) == nil)
        #expect(ComposeLoader.composeFile(at: folder.appending(path: "nope.yaml")) == nil)

        let source = try ComposeLoader.load(url)
        #expect(source.hasDotEnv)
        #expect(source.dotEnv == ["TAG": "2.1", "HOST_PORT": "9090", "EMPTY": "", "QUOTED": "with spaces"])
        #expect(source.overrideFiles == ["compose.override.yaml"])
        #expect(throws: BackendError.self) { try ComposeLoader.load(folder.appending(path: "missing.yaml")) }
    }

    @Test func sessionInterpolatesFromDotEnvAndOverrides() async throws {
        let folder = try folder(
            try ComposeSamples.text("interpolation/compose.yaml"),
            files: [".env": try ComposeSamples.text("interpolation/dot.env"), "compose.override.yml": "x: 1\n"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = ComposeImport()
        session.open(folder.appending(path: "compose.yaml"))
        #expect(session.error == nil)
        #expect(session.references.map(\.name).contains("HOST_PORT"))
        var spec = try #require(session.plan?.runSpec("app"))
        #expect(spec.image == "example/app:2.1")
        #expect(spec.ports.first?.hostPort == 9090)
        #expect(session.plan?.projectName == "demo")
        #expect(session.plan?.warnings.first?.key == "override files")

        // An override typed in the preview wins over `.env`; clearing it falls back.
        session.setVariable("TAG", to: "3.0")
        session.setVariable("PROJECT", to: "prod")
        spec = try #require(session.plan?.runSpec("app"))
        #expect(spec.image == "example/app:3.0")
        #expect(session.plan?.projectName == "prod")
        session.setVariable("TAG", to: nil)
        #expect(session.plan?.runSpec("app")?.image == "example/app:2.1")

        // Options re-plan too.
        session.options.naming = .projectPrefixed
        #expect(session.plan?.containerNames == ["prod-app"])
    }

    @Test func sessionReportsUnreadableFilesAndRequiredVariables() throws {
        let folder = try folder("services:\n  a:\n    image: \"app:${VERSION:?set VERSION}\"\n")
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = ComposeImport()
        session.open(folder.appending(path: "compose.yaml"))
        #expect(session.plan == nil)
        #expect(session.error?.contains("VERSION") == true)
        #expect(session.references.first?.isRequired == true)  // still listed, so the value can be typed
        session.setVariable("VERSION", to: "1")
        #expect(session.error == nil)
        #expect(session.plan?.runSpec("a")?.image == "app:1")

        session.open(folder.appending(path: "does-not-exist.yaml"))
        #expect(session.source == nil)
        #expect(session.error != nil)
    }

    @Test func environmentSnapshotComesFromTheBackend() async throws {
        let backend = MockBackend()
        let environment = await ComposeEnvironment.load(from: backend)
        #expect(environment.isLoaded)
        #expect(environment.dnsDomain == "test")
        #expect(environment.networks.contains("default"))
        #expect(environment.images.contains("docker.io/library/postgres:16-alpine"))
        #expect(environment.containers["probe"] != nil)

        try await backend.systemStop()
        let stopped = await ComposeEnvironment.load(from: backend)
        #expect(!stopped.isLoaded)
        #expect(stopped.containers.isEmpty)
    }

    @Test func runCreatesTheStackAndGroupsItByProject() async throws {
        let folder = try folder(small)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = MockBackend()
        let model = TestSupport.model(backend)
        let session = ComposeImport()
        session.open(folder.appending(path: "compose.yaml"))
        await session.refreshEnvironment(backend: backend)
        let plan = try #require(session.plan)
        #expect(plan.steps.map(\.id) == ["volume:tiny_data", "run:helper", "run:app"])  // image is local: no pull
        #expect(plan.services.first?.hostnames == ["app", "app.test"])

        var finished: Bool?
        let run = try #require(
            session.start(backend: backend, taskCenter: model.taskCenter) { finished = $0 })
        #expect(session.start(backend: backend, taskCenter: model.taskCenter) == nil)  // one run per session
        await run.task?.wait()
        #expect(run.succeeded)
        #expect(finished == true)
        #expect(plan.steps.allSatisfy { run.state(of: $0) == .succeeded })
        #expect(run.created == .init(networks: [], volumes: ["tiny_data"], containers: ["helper", "app"]))

        // The containers carry the label the Containers list groups by, and the Docker Compose ones.
        let containers = try await backend.listContainers(includeStopped: true)
        let app = try #require(containers.first { $0.id == "app" })
        #expect(app.labels[AppLabel.project] == "tiny")
        #expect(app.labels["com.docker.compose.project"] == "tiny")
        #expect(app.labels["com.docker.compose.service"] == "app")
        #expect(try await backend.listVolumes().contains { $0.name == "tiny_data" })
        // Output: a header and the command per step, in the Activity task.
        let lines = run.task?.lines.map(\.text) ?? []
        #expect(lines.contains("── [1/3] Create volume tiny_data ──"))
        #expect(lines.contains { $0.hasPrefix("$ container run -d --name helper") })

        // Importing the same file again: everything collides, and says so.
        await session.backToPreview(backend: backend)
        let again = try #require(session.plan)
        #expect(again.reused == ["volume tiny_data"])
        #expect(again.problems.map(\.kind) == [.containerExists(name: "helper"), .containerExists(name: "app")])
        session.options.replaceExisting = ["helper", "app"]
        #expect(session.plan?.containersToReplace == ["helper", "app"])
        let second = try #require(session.start(backend: backend, taskCenter: model.taskCenter))
        await second.task?.wait()
        #expect(second.succeeded)
        #expect(second.created.volumes.isEmpty)  // reused, so not this run's to remove

        // "Remove what was created" deletes only this run's containers; the reused volume stays.
        #expect(await second.removeCreated(backend: backend).isEmpty)
        #expect(second.created.isEmpty)
        #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id == "app" })
        #expect(try await backend.listVolumes().contains { $0.name == "tiny_data" })
    }

    @Test func runStopsAtTheFirstFailureAndLeavesWhatItCreated() async throws {
        let backend = MockBackend()
        let model = TestSupport.model(backend)
        var plan = ComposePlan(projectName: "broken")
        var spec = RunSpec(image: "docker.io/library/postgres:16-alpine")
        spec.name = "never-started"
        plan.steps = [
            ComposeStep(id: "volume:broken_data", action: .createVolume(name: "broken_data", labels: [:])),
            // The container vanished between planning and running: the delete fails.
            ComposeStep(id: "remove:ghost", action: .removeContainer(name: "ghost")),
            ComposeStep(id: "run:never-started", action: .runContainer(spec)),
        ]
        let run = ComposeRun(plan: plan)
        let task = run.start(backend: backend, taskCenter: model.taskCenter)
        await task.wait()

        #expect(task.state == .failed(.notFound(kind: "container", id: "ghost")))
        #expect(run.failure?.step.id == "remove:ghost")
        #expect(run.state(of: plan.steps[0]) == .succeeded)
        #expect(run.state(of: plan.steps[1]) == .failed(.notFound(kind: "container", id: "ghost")))
        #expect(run.state(of: plan.steps[2]) == .skipped)
        #expect(run.completedCount == 1)
        #expect(run.created == .init(networks: [], volumes: ["broken_data"], containers: []))
        #expect(run.created.summary == "volume broken_data")
        #expect(task.lines.contains { $0.text == "Left in place: volume broken_data." })
        #expect(try await backend.listVolumes().contains { $0.name == "broken_data" })
        #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id == "never-started" })

        #expect(await run.removeCreated(backend: backend).isEmpty)
        #expect(try await !backend.listVolumes().contains { $0.name == "broken_data" })
    }

    @Test func firstStepFailureCreatesNothing() async throws {
        let model = TestSupport.model()
        let plan = ComposeSamples.plan(try ComposeSamples.project("web-stack.yaml"))
        let run = ComposeRun(plan: plan)
        let task = run.start(backend: FailingBackend(error: .systemNotRunning), taskCenter: model.taskCenter)
        await task.wait()
        #expect(task.state == .failed(.systemNotRunning))
        #expect(run.failure?.step.id == "volume:shop_pgdata")
        #expect(run.created.isEmpty)
        #expect(plan.steps.dropFirst().allSatisfy { run.state(of: $0) == .skipped })
    }

    @Test func cancellingSkipsTheRemainingSteps() async throws {
        let backend = MockBackend()
        let model = TestSupport.model(backend)
        var plan = ComposePlan(projectName: "slow")
        var spec = RunSpec(image: "example/slow:1")
        spec.name = "slow"
        plan.steps = [
            ComposeStep(id: "volume:slow_data", action: .createVolume(name: "slow_data", labels: [:])),
            ComposeStep(id: "pull:example/slow:1", action: .pullImage(reference: "example/slow:1", platform: nil)),
            ComposeStep(id: "run:slow", action: .runContainer(spec)),
        ]
        let run = ComposeRun(plan: plan)
        let task = run.start(backend: backend, taskCenter: model.taskCenter)
        while run.state(of: plan.steps[0]) != .succeeded, !task.state.isFinished {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await task.wait()
        #expect(task.state == .cancelled)
        #expect(run.wasCancelled)
        #expect(run.failure == nil)
        #expect(run.state(of: plan.steps[2]) == .skipped)
        #expect(run.created.volumes == ["slow_data"])
        #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id == "slow" })
    }

    @Test func paletteAndRequestsExposeTheImport() {
        let model = TestSupport.model()
        #expect(CommandPalette.actions.contains { $0.action == .importCompose })
        #expect(model.composeRequests.pending == nil)
        model.composeRequests.request()
        #expect(model.composeRequests.pending?.url == nil)
        let url = URL(filePath: "/tmp/compose.yaml")
        model.composeRequests.request(url)
        #expect(model.composeRequests.pending?.url == url)
    }
}
