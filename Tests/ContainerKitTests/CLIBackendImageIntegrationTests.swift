import Foundation
import Testing

@testable import ContainerKit

/// Save as Image (`commit`), image archives, stats and machines against the real `container` CLI. Creates only
/// `cd-it-…` containers, images, machines and temporary folders, and removes them again.
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@Suite("CLIBackend Image Integration", .serialized, .enabled(if: Integration.isEnabled, Integration.hint))
struct CLIBackendImageIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    /// Runs `image` once with `entrypoint` and `arguments`, removes the container, and returns what it printed.
    private func runOnce(_ image: String, entrypoint: String, _ arguments: [String]) async throws -> String {
        var spec = RunSpec(image: image)
        spec.name = Integration.uniqueName("once")
        spec.detach = false
        spec.removeOnExit = true
        spec.entrypoint = entrypoint
        spec.command = arguments
        var lines: [String] = []
        do {
            for try await line in backend.runContainer(spec) where line.stream == .stdout { lines.append(line.text) }
        } catch {
            try? await backend.deleteContainer(spec.name ?? "", force: true)
            throw error
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Commit (Save as Image)

    /// Skipped on a CLI without `commit` (before container 1.6), where
    /// `CLIBackendExportIntegrationTests.commitIsReportedAsUnsupportedWhereTheCLILacksIt` covers the refusal.
    @Test func commitSavesAnImageThatIsListedAndRuns() async throws {
        guard await backend.supportsCommit() else { return }
        let repository = Integration.uniqueName("img")
        let reference = "\(repository):v1"
        let stoppedReference = "\(repository):stopped"
        defer {
            let backend = backend
            Task { for tag in [reference, stoppedReference] { try? await backend.deleteImage(tag) } }
        }
        do {
            try await Integration.withContainer(backend, configure: { $0.labels = ["cd-it": "commit"] }) { id in
                try await Integration.shell(
                    backend, id, "mkdir /saved && printf 'kept by commit' > /saved/marker && sync")

                var lines: [String] = []
                for try await line in backend.commitContainer(id, reference: reference) { lines.append(line.text) }
                // The CLI prints the normalised reference of the new image.
                #expect(lines.last == "docker.io/library/\(reference)")

                let listed = try #require(try await backend.listImages().first { $0.reference.hasSuffix(reference) })
                #expect(listed.repository == repository && listed.tag == "v1")
                let image = try await backend.inspectImage(reference)
                // The container's process becomes the image's entrypoint (executable) and command (arguments),
                // and the container's labels are copied.
                let config = try #require(image.variants.first?.config?.config)
                #expect(config.entrypoint == ["sleep"] && config.cmd == ["600"])
                #expect(config.labels?["cd-it"] == "commit")

                // The filesystem change is in the image, and the image runs.
                #expect(try await runOnce(reference, entrypoint: "cat", ["/saved/marker"]) == "kept by commit")
                var again = RunSpec(image: reference)
                again.name = Integration.uniqueName("from-img")
                for try await _ in backend.runContainer(again) {}
                let rerun = try await backend.inspectContainer(again.name ?? "")
                #expect(rerun.isRunning && rerun.commandLine == "sleep 600", "runs the committed process by default")
                try await backend.deleteContainer(rerun.id, force: true)

                // A stopped container commits too.
                try await backend.stopContainer(id, timeoutSeconds: 1, signal: nil)
                for try await _ in backend.commitContainer(id, reference: stoppedReference) {}
                #expect(try await backend.inspectImage(stoppedReference).reference.hasSuffix(stoppedReference))

                // An invalid reference is the CLI's error, not `.unsupported`.
                let invalid = await Integration.backendError {
                    for try await _ in backend.commitContainer(id, reference: "Not A Reference") {}
                }
                guard case .commandFailed(_, 1, let message) = invalid else {
                    Issue.record("expected commandFailed, got \(String(describing: invalid))")
                    return
                }
                #expect(message.contains("invalid format for image reference"))
            }
            // A container that does not exist.
            let ghost = Integration.uniqueName("ghost")
            let missing = await Integration.backendError {
                for try await _ in backend.commitContainer(ghost, reference: "\(repository):ghost") {}
            }
            #expect(missing == .notFound(kind: "container", id: ghost), "\(String(describing: missing))")
        } catch {
            for tag in [reference, stoppedReference] { try? await backend.deleteImage(tag) }
            throw error
        }
        try await backend.deleteImage(reference)
        try await backend.deleteImage(stoppedReference)
        #expect(try await !backend.listImages().contains { $0.repository == repository })
    }

    // MARK: Image archives

    /// One platform of an image saves and loads back. "All platforms" only works when every platform in the
    /// image's index is on disk; for an image pulled for this Mac alone the CLI fails, and the error says why.
    @Test func savesAnImageToATarAndLoadsItBack() async throws {
        let folder = try Integration.makeTemporaryFolder("save")
        defer { try? FileManager.default.removeItem(at: folder) }
        let reference = "\(Integration.uniqueName("tag")):saved"
        let tar = folder.appending(path: "image archive.tar").path(percentEncoded: false)
        do {
            try await backend.tagImage(Integration.busyBoxImage, newReference: reference)
            let image = try await backend.inspectImage(reference)
            let host = try #require(image.platforms.first { $0.architecture == "arm64" && $0.os == "linux" })

            try await backend.saveImages([reference], to: tar, platform: host)
            let size = try FileManager.default.attributesOfItem(atPath: tar)[.size] as? Int ?? 0
            #expect(size > 1_000_000)
            #expect(try CLIBackendExportIntegrationTests.tarEntries(URL(filePath: tar)).contains("index.json"))

            let everything = folder.appending(path: "all platforms.tar").path(percentEncoded: false)
            let failure = await Integration.backendError {
                try await backend.saveImages([reference], to: everything, platform: nil)
            }
            if let failure {
                guard case .commandFailed(_, 1, let message) = failure else {
                    Issue.record("expected commandFailed, got \(failure)")
                    return
                }
                #expect(message.hasPrefix("content with digest sha256:"))
                #expect(message.contains("Choose a single platform"))
            }

            try await backend.deleteImage(reference)
            #expect(try await !backend.listImages().contains { $0.reference.hasSuffix(reference) })
            try await backend.loadImages(from: tar)
            let loaded = try await backend.inspectImage(reference)
            #expect(loaded.reference.hasSuffix(reference))
            #expect(try await runOnce(reference, entrypoint: "echo", ["loaded"]) == "loaded")
        } catch {
            try? await backend.deleteImage(reference)
            throw error
        }
        try await backend.deleteImage(reference)
    }

    // MARK: Build

    /// `container build` (a plugin) reports its steps while it runs, not all at once when it ends: the first
    /// line arrives well before a step that sleeps for three seconds has finished.
    @Test(.timeLimit(.minutes(10)))
    func buildStreamsItsProgress() async throws {
        let folder = try Integration.makeTemporaryFolder("build")
        defer { try? FileManager.default.removeItem(at: folder) }
        let dockerfile = "FROM alpine:latest\nRUN echo cd-it-step-one\nRUN sleep 3 && echo cd-it-step-two\n"
        try Data(dockerfile.utf8).write(to: folder.appending(path: "Dockerfile"))
        let tag = "\(Integration.uniqueName("build")):latest"
        var spec = BuildSpec(contextDirectory: folder.path(percentEncoded: false), tag: tag)
        spec.noCache = true
        let clock = ContinuousClock()
        var firstLine: ContinuousClock.Instant?
        var lines: [String] = []
        do {
            for try await line in backend.buildImage(spec) {
                if firstLine == nil { firstLine = clock.now }
                lines.append(line.text)
            }
            let finished = clock.now
            #expect(lines.count > 5, "\(lines)")
            #expect(lines.contains { $0.contains("cd-it-step-one") } && lines.contains { $0.contains("sleep 3") })
            let first = try #require(firstLine)
            #expect(finished - first > .seconds(2), "all output arrived at the end: \(finished - first)")
            #expect(try await backend.inspectImage(tag).reference.hasSuffix(tag))
        } catch {
            try? await backend.deleteImage(tag)
            throw error
        }
        try await backend.deleteImage(tag)
    }

    // MARK: Stats

    /// `cpuUtilization` is used when the CLI prints it (container 1.7) and absent otherwise; the test reads the
    /// raw JSON to know which.
    @Test func statsDecodeWithOrWithoutCPUUtilization() async throws {
        try await Integration.withContainer(backend, command: ["sh", "-c", "while :; do :; done"]) { id in
            let raw = try await backend.execute(["stats", "--no-stream", "--format", "json", "--", id])
            let reportsUtilization = raw.stdoutText.contains("\"cpuUtilization\"")
            let sample = try #require(try await backend.containerStats(ids: [id]).first)
            #expect(sample.id == id && sample.memoryLimitBytes > 0 && sample.numProcesses >= 1)
            if reportsUtilization {
                // A busy loop on one core: clearly more than idle, at most a little over one core.
                let utilization = try #require(sample.cpuUtilization)
                #expect(utilization > 0.2 && utilization < 1.5, "\(utilization)")
                #expect(sample.reportedCPUPercent == utilization * 100)
                #expect(ContainerStats.cpuPercent(previous: sample, current: sample, interval: 0) == utilization * 100)
            } else {
                #expect(sample.cpuUtilization == nil && sample.reportedCPUPercent == nil)
            }
            let all = try await backend.containerStats(ids: [])
            #expect(all.contains { $0.id == id })
            // Not "every row has it": a container that stops during the CLI's two-second measurement is listed
            // without the figure (seen on 1.7.1), and the app then computes CPU from two samples as before.
            if !reportsUtilization { #expect(all.allSatisfy { $0.cpuUtilization == nil }) }
        }
    }

    // MARK: Machines

    /// A machine that is created but never booted: listed, inspected and deleted. Verified on container 1.7.1.
    @Test(.timeLimit(.minutes(10)))
    func machineCreatedWithoutBootIsListedInspectedAndDeleted() async throws {
        let name = Integration.uniqueName("m")
        var spec = MachineSpec(image: Integration.busyBoxImage, name: name)
        spec.cpus = 2
        spec.memory = MemorySize(bytes: 2 << 30)
        spec.homeMount = "none"
        spec.noBoot = true
        do {
            var lines: [String] = []
            for try await line in backend.createMachine(spec) { lines.append(line.text) }
            #expect(lines.last == name)
            let listed = try #require(try await backend.listMachines().first { $0.id == name })
            #expect(listed.status == .stopped && listed.cpus == 2 && listed.memory == 2 << 30 && listed.diskSize > 0)
            let machine = try await backend.inspectMachine(name)
            #expect(machine.id == name && machine.homeMount == "none")
            #expect(machine.image?.reference.hasSuffix("alpine:latest") == true)
            try await backend.deleteMachine(name)
        } catch {
            try? await backend.deleteMachine(name)
            throw error
        }
        #expect(try await !backend.listMachines().contains { $0.id == name })
    }
}
