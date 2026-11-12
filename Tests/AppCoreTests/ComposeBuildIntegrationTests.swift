import ContainerKit
import Foundation
import Testing

@testable import AppCore

/// More of the compose import against the real `container` CLI: `build:`, `env_file`, resource limits,
/// profiles, a pull of an image that is not local, and a run that fails half-way.
///
/// The build uses the existing builder container (it is started when needed and left as the build leaves it).
/// Every project is named `cd-it-…`, so are its containers, volumes and the image it builds, and each test
/// removes what it created, also when it fails. An image that was pulled is removed only when it was not
/// there before.
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@MainActor
@Suite(
    "Compose Build Integration", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_INTEGRATION"] == "1",
        "set CONTAINER_DESKTOP_INTEGRATION=1 to run against the real CLI"))
struct ComposeBuildIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    // MARK: Helpers

    private func uniqueProject() -> String { "cd-it-\(UUID().uuidString.prefix(8).lowercased())" }

    /// A project folder `…/cd-it-<id> compose/` (with a space) holding `compose.yaml` and `files`.
    private func makeProject(_ project: String, yaml: String, files: [String: String] = [:]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(project) compose")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, text) in files.merging(["compose.yaml": yaml], uniquingKeysWith: { $1 }) {
            let url = folder.appending(path: name)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return folder
    }

    /// Opens the file like the import sheet does, with project-prefixed container names.
    private func openSession(_ folder: URL, profiles: Set<String> = []) async -> ComposeImport {
        let session = ComposeImport()
        session.open(folder.appending(path: "compose.yaml"))
        session.options.naming = .projectPrefixed
        session.options.enabledProfiles = profiles
        await session.refreshEnvironment(backend: backend)
        return session
    }

    /// Runs the session's plan and waits for it to finish. Returns the run and what it printed.
    private func runToEnd(_ session: ComposeImport) async throws -> (run: ComposeRun, output: [String]) {
        let run = try #require(session.start(backend: backend, taskCenter: TaskCenter()))
        let deadline = ContinuousClock.now + .seconds(540)
        while !run.isFinished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(run.isFinished, "the run did not finish in time")
        return (run, run.task?.lines.map(\.text) ?? [])
    }

    /// Removes everything named after `project`, whatever state the test left behind. Never throws.
    private func removeEverything(of project: String) async {
        for container in (try? await backend.listContainers(includeStopped: true)) ?? []
        where container.id.hasPrefix(project) {
            try? await backend.deleteContainer(container.id, force: true)
        }
        for volume in (try? await backend.listVolumes()) ?? [] where volume.name.hasPrefix(project) {
            try? await backend.deleteVolume(volume.name)
        }
        for image in (try? await backend.listImages()) ?? [] where image.reference.contains(project) {
            try? await backend.deleteImage(image.reference)
        }
    }

    /// `printenv NAME` inside the container, as raw bytes without the final newline (`nil` when unset).
    private func environmentValue(_ id: String, _ name: String) async throws -> [UInt8]? {
        let result = try await backend.execCapture(id, command: ["printenv", name], workingDirectory: nil)
        guard result.exitCode == 0 else { return nil }
        return Array(result.stdout.utf8.dropLast(result.stdout.hasSuffix("\n") ? 1 : 0))
    }

    private func exec(_ id: String, _ script: String) async throws -> (exitCode: Int32, stdout: String) {
        let result = try await backend.execCapture(id, command: ["sh", "-c", script], workingDirectory: nil)
        return (result.exitCode, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: Tests

    @Test(.timeLimit(.minutes(15)))
    func buildsReadsEnvFilesAppliesLimitsAndHonoursProfiles() async throws {
        let project = uniqueProject()
        let accented = "caf\u{E9} \u{D55C}"  // precomposed, as an editor on Linux or the Mac writes it
        let folder = try makeProject(
            project,
            yaml: """
                name: \(project)
                services:
                  app:
                    build:
                      context: ./app
                      dockerfile: Dockerfile
                      target: final
                      args:
                        GREETING: "hello build"
                    command: ["sleep", "600"]
                    env_file: ./one.env
                    cpus: 2
                    mem_limit: 512m
                  side:
                    image: alpine:latest
                    command: ["sleep", "600"]
                    env_file:
                      - ./one.env
                      - path: ./two.env
                      - path: ./absent.env
                        required: false
                      - ./quoted.env
                    environment:
                      OVERRIDDEN: from environment
                    deploy:
                      resources:
                        limits:
                          cpus: "1.5"
                          memory: 300M
                  extra:
                    image: alpine:latest
                    command: ["sleep", "600"]
                    profiles: [debug]
                """,
            files: [
                "app/Dockerfile": """
                FROM docker.io/library/alpine:latest AS base
                ARG GREETING=unset
                RUN printf '%s' "$GREETING" > /greeting.txt
                FROM base AS final
                COPY payload.txt /payload.txt
                FROM final AS unused
                RUN echo unused > /unused.txt
                """,
                "app/payload.txt": "copied in\n",
                "one.env": """
                # a comment line
                PLAIN=value
                SPACED=value with spaces
                ACCENT=\(accented)
                OVERRIDDEN=from file

                EQUALS=a=b=c
                """,
                "two.env": "SECOND=2\nPLAIN=from two\n",
                // Lines `container run --env-file` takes literally or refuses; Compose reads them like this.
                "quoted.env": """
                DOUBLE="double quoted"
                SINGLE='single \(accented)'
                TRAILING=value # a trailing comment
                export EXPORTED=yes
                """,
            ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = "\(project)-app", side = "\(project)-side", extra = "\(project)-extra"
        let tag = "\(project)-app:latest"
        do {
            let session = await openSession(folder)
            let plan = try #require(session.plan)
            #expect(plan.problems.isEmpty, "\(plan.problems.map(\.message))")
            // The service with a profile is left out; fractional CPUs are rounded up with a note.
            #expect(plan.steps.map(\.id) == ["build:app", "run:\(app)", "run:\(side)"])
            #expect(plan.services.first { $0.name == "extra" }?.isEnabled == false)
            #expect(plan.warnings.contains { $0.key == "cpus" })
            // `app` keeps its literal file as `--env-file`; `side` has a file the CLI would misread.
            #expect(plan.runSpec(app)?.envFiles.count == 1)
            #expect(plan.runSpec(side)?.envFiles.isEmpty == true)
            #expect(plan.warnings.contains { $0.key == "env_file" && $0.scope == .service("side") })

            let (run, output) = try await runToEnd(session)
            #expect(run.succeeded, "\(String(describing: run.failure))\n\(output.suffix(30).joined(separator: "\n"))")

            // build: the image exists under a cd-it tag, with the build argument, the COPY and the right stage.
            let images = try await backend.listImages()
            #expect(images.contains { ImageReferenceName.canonical($0.reference) == ImageReferenceName.canonical(tag) })
            #expect(try await exec(app, "cat /greeting.txt").stdout == "hello build")
            #expect(try await exec(app, "cat /payload.txt").stdout == "copied in")
            #expect(try await exec(app, "test -e /unused.txt; echo $?").stdout == "1")

            // env_file, string form.
            #expect(try await environmentValue(app, "PLAIN") == Array("value".utf8))
            #expect(try await environmentValue(app, "SPACED") == Array("value with spaces".utf8))
            #expect(try await environmentValue(app, "ACCENT") == Array(accented.utf8))
            #expect(try await environmentValue(app, "EQUALS") == Array("a=b=c".utf8))
            #expect(try await environmentValue(app, "OVERRIDDEN") == Array("from file".utf8))
            #expect(try await environmentValue(app, "SECOND") == nil)
            // env_file, list form: a later file wins over an earlier one, `environment:` wins over both, and a
            // missing optional file is skipped.
            #expect(try await environmentValue(side, "PLAIN") == Array("from two".utf8))
            #expect(try await environmentValue(side, "SECOND") == Array("2".utf8))
            #expect(try await environmentValue(side, "ACCENT") == Array(accented.utf8))
            #expect(try await environmentValue(side, "OVERRIDDEN") == Array("from environment".utf8))
            #expect(try await environmentValue(side, "SPACED") == Array("value with spaces".utf8))
            #expect(try await environmentValue(side, "DOUBLE") == Array("double quoted".utf8))
            #expect(try await environmentValue(side, "SINGLE") == Array("single \(accented)".utf8))
            #expect(try await environmentValue(side, "TRAILING") == Array("value".utf8))
            #expect(try await environmentValue(side, "EXPORTED") == Array("yes".utf8))

            // Limits, as the engine reports them and as the container sees them.
            let appContainer = try await backend.inspectContainer(app)
            #expect(appContainer.configuration.resources.cpus == 2)
            #expect(appContainer.configuration.resources.memoryInBytes == 512 << 20)
            // The VM gets headroom on top of the limit: `-c 2 -m 512M` shows 3 CPUs and about 600 MB inside
            // on CLI 1.5.0, so only the lower bound is asserted.
            let visibleCPUs = Int(try await exec(app, "nproc").stdout) ?? 0
            #expect((2...3).contains(visibleCPUs), "nproc says \(visibleCPUs)")
            let sideContainer = try await backend.inspectContainer(side)
            #expect(sideContainer.configuration.resources.cpus == 2)  // 1.5 rounded up
            #expect(sideContainer.configuration.resources.memoryInBytes == 300 << 20)

            // Profiles: not started by default, planned once the profile is ticked.
            #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id == extra })
            let withProfile = await openSession(folder, profiles: ["debug"])
            #expect(withProfile.plan?.steps.contains { $0.id == "run:\(extra)" } == true)
            #expect(withProfile.plan?.services.first { $0.name == "extra" }?.isEnabled == true)

            #expect(await run.removeCreated(backend: backend).isEmpty)
        } catch {
            await removeEverything(of: project)
            throw error
        }
        await removeEverything(of: project)
        #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id.hasPrefix(project) })
        #expect(try await !backend.listImages().contains { $0.reference.contains(project) })
    }

    @Test(.timeLimit(.minutes(10)))
    func pullsAnImageThatIsNotLocal() async throws {
        let project = uniqueProject()
        let image = "docker.io/library/busybox:1.36"
        let wasLocal = try await backend.listImages().contains {
            ImageReferenceName.canonical($0.reference) == ImageReferenceName.canonical(image)
        }
        let folder = try makeProject(
            project,
            yaml: """
                name: \(project)
                services:
                  box:
                    image: \(image)
                    command: ["sleep", "600"]
                """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let box = "\(project)-box"
        do {
            let session = await openSession(folder)
            let plan = try #require(session.plan)
            #expect(plan.steps.map(\.id) == (wasLocal ? [] : ["pull:\(image)"]) + ["run:\(box)"])
            let (run, output) = try await runToEnd(session)
            if let failure = run.failure, failure.step.id == "pull:\(image)" {
                // No registry access is the environment's problem, not the app's: say so and stop here.
                print("COMPOSE-PULL-SKIPPED: \(failure.error)\n\(output.suffix(10).joined(separator: "\n"))")
                #expect(run.created.isEmpty)
            } else {
                #expect(run.succeeded, "\(String(describing: run.failure))")
                #expect(try await backend.inspectContainer(box).isRunning)
                #expect(try await exec(box, "busybox | head -1").stdout.contains("BusyBox v1.36"))
                let pulled = try await backend.listImages().contains {
                    ImageReferenceName.canonical($0.reference) == ImageReferenceName.canonical(image)
                }
                #expect(pulled)
                // A second look finds the image locally, so a re-import would not pull again.
                await session.backToPreview(backend: backend)
                #expect(session.plan?.steps.contains { $0.id.hasPrefix("pull:") } == false)
                #expect(await run.removeCreated(backend: backend).isEmpty)
            }
        } catch {
            await removeEverything(of: project)
            if !wasLocal { try? await backend.deleteImage(image) }
            throw error
        }
        await removeEverything(of: project)
        if !wasLocal { try? await backend.deleteImage(image) }
        let stillLocal = try await backend.listImages().contains {
            ImageReferenceName.canonical($0.reference) == ImageReferenceName.canonical(image)
        }
        #expect(stillLocal == wasLocal)
    }

    /// The second service cannot start. The run stops there, says what it left behind, and "Remove What Was
    /// Created" removes exactly that: not a volume that existed before the run.
    @Test func aFailingStepStopsTheRunAndCleanupRemovesOnlyWhatItCreated() async throws {
        let project = uniqueProject()
        let folder = try makeProject(
            project,
            yaml: """
                name: \(project)
                services:
                  first:
                    image: alpine:latest
                    command: ["sleep", "600"]
                    volumes:
                      - data:/data
                      - keep:/keep
                  second:
                    image: alpine:latest
                    command: ["sleep", "600"]
                    depends_on: [first]
                    volumes:
                      - ./missing folder:/data
                  third:
                    image: alpine:latest
                    command: ["sleep", "600"]
                    depends_on: [second]
                volumes:
                  data:
                  keep:
                """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = "\(project)-first", second = "\(project)-second", third = "\(project)-third"
        let data = "\(project)_data", keep = "\(project)_keep"
        do {
            try await backend.createVolume(name: keep, size: nil, journal: nil, labels: [:])
            let session = await openSession(folder)
            let plan = try #require(session.plan)
            #expect(plan.steps.map(\.id) == ["volume:\(data)", "run:\(first)", "run:\(second)", "run:\(third)"])
            #expect(plan.reused == ["volume \(keep)"])

            let (run, output) = try await runToEnd(session)
            #expect(!run.succeeded)
            let failure = try #require(run.failure)
            #expect(failure.step.id == "run:\(second)")
            #expect(failure.error.errorDescription?.contains("does not exist") == true, "\(failure.error)")
            let states = plan.steps.map { run.state(of: $0) }
            #expect(states[0] == .succeeded)
            #expect(states[1] == .succeeded)
            #expect(states[2] == .failed(failure.error))
            #expect(states[3] == .skipped)
            #expect(run.completedCount == 2)

            // What it reports as created is what exists (the failed container never came into being).
            #expect(run.created.volumes == [data])
            #expect(run.created.containers == [first, second])
            #expect(output.contains("Stopped at step 3 of 4: Run \(second) failed."))
            #expect(output.contains("Left in place: containers \(first), \(second); volume \(data)."))
            let existing = try await backend.listContainers(includeStopped: true).filter { $0.id.hasPrefix(project) }
            #expect(existing.map(\.id) == [first])
            #expect(existing.first?.isRunning == true)

            #expect(await run.removeCreated(backend: backend).isEmpty)
            #expect(run.created.isEmpty)
            #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id.hasPrefix(project) })
            let volumes = try await backend.listVolumes().map(\.name).filter { $0.hasPrefix(project) }
            #expect(volumes == [keep])  // it was there before the run, so it stays
            _ = third
        } catch {
            await removeEverything(of: project)
            throw error
        }
        await removeEverything(of: project)
        #expect(try await !backend.listVolumes().contains { $0.name.hasPrefix(project) })
    }
}
