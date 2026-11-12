import ContainerKit
import Foundation
import Testing

@testable import AppCore

/// Compose import end to end against the real `container` CLI: file → plan → run → what really exists.
///
/// Uses local images only (`redis:7-alpine`, `alpine:latest`). Every project is named `cd-it-…`, so are its
/// containers, volumes and networks, and each test removes what it created, also when it fails.
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@MainActor
@Suite(
    "Compose Integration", .serialized,
    .enabled(
        if: ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_INTEGRATION"] == "1",
        "set CONTAINER_DESKTOP_INTEGRATION=1 to run against the real CLI"))
struct ComposeIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    // MARK: Helpers

    /// A project folder `…/cd-it-<id> compose/` (with a space) holding `compose.yaml` and a `shared/` folder.
    private func makeProject(_ project: String, yaml: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "\(project) compose")
        try FileManager.default.createDirectory(at: folder.appending(path: "shared"), withIntermediateDirectories: true)
        try Data("hello from the mac\n".utf8).write(to: folder.appending(path: "shared/hello.txt"))
        try Data(yaml.utf8).write(to: folder.appending(path: "compose.yaml"))
        return folder
    }

    /// Opens the file like the import sheet does, with project-prefixed container names so nothing can collide
    /// with the owner's containers.
    private func openSession(
        _ folder: URL, networking: ComposeOptions.Networking = .sharedDefault
    ) async -> ComposeImport {
        let session = ComposeImport()
        session.open(folder.appending(path: "compose.yaml"))
        session.options.naming = .projectPrefixed
        session.options.networking = networking
        await session.refreshEnvironment(backend: backend)
        return session
    }

    /// Runs the session's plan and waits for it to finish.
    private func runToEnd(_ session: ComposeImport) async throws -> ComposeRun {
        let run = try #require(session.start(backend: backend, taskCenter: TaskCenter()))
        let deadline = ContinuousClock.now + .seconds(180)
        while !run.isFinished, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        #expect(run.isFinished, "the run did not finish in time")
        return run
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
        for network in (try? await backend.listNetworks()) ?? [] where network.name.hasPrefix(project) {
            try? await backend.deleteNetwork(network.name)
        }
    }

    private func exec(_ id: String, _ script: String) async throws -> (exitCode: Int32, stdout: String) {
        let result = try await backend.execCapture(id, command: ["sh", "-c", script], workingDirectory: nil)
        return (result.exitCode, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Sends `PING` to a Redis server on `localhost:port` with `/usr/bin/nc` and returns the reply.
    private nonisolated func redisPing(port: Int) async -> String {
        await withCheckedContinuation { continuation in
            // `nc` stops at end of input, so the pipe is held open long enough for the reply to arrive.
            let process = Process()
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = [
                "-c", #"(printf 'PING\r\n'; sleep 1) | /usr/bin/nc -w 2 127.0.0.1 "$1""#, "sh", String(port),
            ]
            let output = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: "")
            }
        }
    }

    // MARK: Tests

    @Test func runsAProjectEndToEnd() async throws {
        let project = "cd-it-\(UUID().uuidString.prefix(8).lowercased())"
        let port = Int.random(in: 20_000...60_000)
        let folder = try makeProject(
            project,
            yaml: """
                name: \(project)
                services:
                  worker:
                    image: alpine:latest
                    command: ["sleep", "600"]
                    depends_on: [cache]
                    working_dir: /shared
                    environment:
                      - MODE=integration test
                    volumes:
                      - ./shared:/shared
                  cache:
                    image: redis:7-alpine
                    ports:
                      - "\(port):6379"
                    environment:
                      CD_IT_GREETING: "hello world"
                    volumes:
                      - cachedata:/data
                      - type: tmpfs
                        target: /scratch
                        tmpfs:
                          size: 16m
                    labels:
                      cd.it.custom: "yes"
                volumes:
                  cachedata:
                """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = "\(project)-cache", worker = "\(project)-worker", volume = "\(project)_cachedata"
        do {
            let session = await openSession(folder)
            let plan = try #require(session.plan)
            #expect(session.error == nil)
            #expect(session.environment.isLoaded)
            #expect(plan.projectName == project)
            #expect(plan.problems.isEmpty, "\(plan.problems.map(\.message))")
            // Both images are local, so nothing is pulled; the dependency starts first.
            #expect(plan.steps.map(\.id) == ["volume:\(volume)", "run:\(cache)", "run:\(worker)"])
            #expect(plan.containerNames == [cache, worker])

            let run = try await runToEnd(session)
            #expect(run.succeeded, "\(String(describing: run.failure))")
            #expect(run.created.containers == [cache, worker])
            #expect(run.created.volumes == [volume])
            #expect(run.created.networks.isEmpty)

            // What exists, with the labels the Containers list groups by.
            let containers = try await backend.listContainers(includeStopped: true).filter { $0.id.hasPrefix(project) }
            #expect(Set(containers.map(\.id)) == [cache, worker])
            for container in containers {
                #expect(container.isRunning, "\(container.id)")
                #expect(container.labels[AppLabel.project] == project)
                #expect(container.labels[ComposePlanner.DockerLabel.project] == project)
            }
            let cacheContainer = try await backend.inspectContainer(cache)
            #expect(cacheContainer.labels[ComposePlanner.DockerLabel.service] == "cache")
            #expect(cacheContainer.labels["cd.it.custom"] == "yes")
            #expect(cacheContainer.configuration.publishedPorts.map(\.hostPort) == [port])
            #expect(
                cacheContainer.configuration.mounts.contains { mount in
                    if case .volume(let name, _) = mount.type {
                        name == volume && mount.destination == "/data"
                    } else {
                        false
                    }
                })
            let created = try await backend.inspectVolume(volume)
            #expect(created.configuration.labels[AppLabel.project] == project)

            // Environment, tmpfs with a size, bind mount and working directory are really there.
            #expect(try await exec(cache, "printenv CD_IT_GREETING").stdout == "hello world")
            #expect(try await exec(cache, "df -k /scratch | tail -1 | awk '{print $1, $2}'").stdout == "tmpfs 16384")
            #expect(try await exec(cache, "mount | grep -c ' /data '").stdout == "1")
            #expect(try await exec(worker, "printenv MODE").stdout == "integration test")
            #expect(try await exec(worker, "pwd && cat hello.txt").stdout == "/shared\nhello from the mac")
            #expect(try await exec(worker, "echo from the container > /shared/back.txt").exitCode == 0)
            #expect(
                try String(contentsOf: folder.appending(path: "shared/back.txt"), encoding: .utf8)
                    == "from the container\n")

            // The published port answers on the Mac.
            var reply = ""
            for _ in 0..<40 where !reply.contains("+PONG") {
                reply = await redisPing(port: port)
                if !reply.contains("+PONG") { try await Task.sleep(for: .milliseconds(250)) }
            }
            #expect(reply.contains("+PONG"), "no reply from redis on localhost:\(port)")

            // What the preview says about names must be what really happens between the two containers.
            let summary = try #require(plan.services.first { $0.name == "cache" })
            let byName = try await exec(worker, "ping -c 1 -W 2 \(cache) >/dev/null 2>&1; echo $?").stdout == "0"
            #expect(byName == !summary.hostnames.isEmpty, "preview: \(plan.namingSummary)")
            let address = try #require(cacheContainer.status?.networks.first?.ipv4Address.split(separator: "/").first)
            #expect(try await exec(worker, "ping -c 1 -W 2 \(address) >/dev/null 2>&1; echo $?").stdout == "0")
            if session.environment.dnsDomain == nil {
                #expect(!byName)
                #expect(plan.warnings.contains { $0.key == "names" })
            }

            // A second look at the engine now reports both names as taken.
            await session.backToPreview(backend: backend)
            let blocked = try #require(session.plan)
            #expect(!blocked.canRun)
            #expect(
                Set(blocked.problems.compactMap { if case .containerExists(let name) = $0.kind { name } else { nil } })
                    == [cache, worker])
            #expect(blocked.reused == ["volume \(volume)"])

            // "Remove What Was Created" removes all of it.
            #expect(await run.removeCreated(backend: backend).isEmpty)
            #expect(run.created.isEmpty)
        } catch {
            await removeEverything(of: project)
            throw error
        }
        await removeEverything(of: project)
        #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id.hasPrefix(project) })
        #expect(try await !backend.listVolumes().contains { $0.name.hasPrefix(project) })
    }

    /// "Networks from the file": networks are created, a service is attached to two of them by repeating
    /// `--network`, and `entrypoint:` without `command:` drops the image's default command.
    @Test func attachesDeclaredNetworksAndOverridesTheEntrypoint() async throws {
        let project = "cd-it-\(UUID().uuidString.prefix(8).lowercased())"
        let folder = try makeProject(
            project,
            yaml: """
                name: \(project)
                services:
                  both:
                    image: alpine:latest
                    command: ["sleep", "600"]
                    networks: [front, back]
                  backonly:
                    image: alpine:latest
                    entrypoint: ["sleep"]
                    command: ["600"]
                    networks: [back]
                  bare:
                    image: redis:7-alpine
                    entrypoint: /bin/hostname
                networks:
                  front:
                  back:
                """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let both = "\(project)-both", backOnly = "\(project)-backonly", bare = "\(project)-bare"
        do {
            let session = await openSession(folder, networking: .asDeclared)
            let plan = try #require(session.plan)
            #expect(plan.problems.isEmpty, "\(plan.problems.map(\.message))")
            let run = try await runToEnd(session)
            #expect(run.succeeded, "\(String(describing: run.failure))")
            // `bare` has no `networks:`, so it joins the project's default network, which is created too.
            #expect(Set(run.created.networks) == ["\(project)_front", "\(project)_back", "\(project)_default"])
            let networks = try await backend.listNetworks().filter { $0.name.hasPrefix(project) }
            #expect(networks.count == 3)

            let attached = try await backend.inspectContainer(both)
            #expect(attached.configuration.networks.map(\.network) == ["\(project)_front", "\(project)_back"])
            #expect(attached.status?.networks.count == 2)
            #expect(try await exec(both, "ls /sys/class/net | grep -c eth").stdout == "2")

            // Same network: reachable by IP address. By name only if the preview promised it (it does not).
            let peer = try await backend.inspectContainer(backOnly)
            #expect(peer.configuration.initProcess.executable == "sleep")
            #expect(peer.configuration.initProcess.arguments == ["600"])
            let address = try #require(peer.status?.networks.first?.ipv4Address.split(separator: "/").first)
            #expect(try await exec(both, "ping -c 1 -W 2 \(address) >/dev/null 2>&1; echo $?").stdout == "0")
            let byName = try await exec(both, "ping -c 1 -W 2 \(backOnly) >/dev/null 2>&1; echo $?").stdout == "0"
            let summary = try #require(plan.services.first { $0.name == "backonly" })
            #expect(summary.hostnames.isEmpty)
            #expect(byName == !summary.hostnames.isEmpty, "preview: \(plan.namingSummary)")

            // `--entrypoint` alone: the image's CMD (`redis-server`) is not passed to the new entrypoint.
            let overridden = try await backend.inspectContainer(bare)
            #expect(overridden.configuration.initProcess.executable == "/bin/hostname")
            #expect(overridden.configuration.initProcess.arguments.isEmpty)
            var lines: [String] = []
            for try await line in backend.containerLogs(bare, follow: false, boot: false, tail: nil) {
                lines.append(line.text)
            }
            #expect(lines.contains(bare))  // the container's name is its hostname

            #expect(await run.removeCreated(backend: backend).isEmpty)
        } catch {
            await removeEverything(of: project)
            throw error
        }
        await removeEverything(of: project)
        #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id.hasPrefix(project) })
        #expect(try await !backend.listNetworks().contains { $0.name.hasPrefix(project) })
    }

    /// Docker creates a missing bind-mount folder; this runtime refuses to start the container. The run stops
    /// at that step with the CLI's message, and the preview had warned about it.
    @Test func missingBindSourceStopsTheRun() async throws {
        let project = "cd-it-\(UUID().uuidString.prefix(8).lowercased())"
        let folder = try makeProject(
            project,
            yaml: """
                name: \(project)
                services:
                  app:
                    image: alpine:latest
                    command: ["sleep", "600"]
                    volumes:
                      - ./missing folder:/data
                """)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let session = await openSession(folder)
            let plan = try #require(session.plan)
            #expect(plan.warnings.contains { $0.key == "volumes" && $0.message.contains("does not exist") })
            let run = try await runToEnd(session)
            #expect(!run.succeeded)
            let failure = try #require(run.failure)
            #expect(failure.step.id == "run:\(project)-app")
            #expect(failure.error.errorDescription?.contains("does not exist") == true, "\(failure.error)")
            // The folder was not created on the Mac, and no container was left behind.
            #expect(
                !FileManager.default.fileExists(
                    atPath: folder.appending(path: "missing folder").path(percentEncoded: false)))
            #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id.hasPrefix(project) })
            #expect(await run.removeCreated(backend: backend).isEmpty)
        } catch {
            await removeEverything(of: project)
            throw error
        }
        await removeEverything(of: project)
    }
}
