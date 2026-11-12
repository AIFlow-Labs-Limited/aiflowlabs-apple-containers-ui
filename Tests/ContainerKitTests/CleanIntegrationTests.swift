import Foundation
import Testing

@testable import ContainerKit

/// `container clean` (Apple container 1.7+) against the real CLI: that it gives space back to the Mac and that
/// it deletes nothing. Creates one `cd-it-reg-clean-…` container and one `cd-it-reg-clean-vol-…` volume and
/// removes both. Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@Suite("Clean Integration", .serialized, .enabled(if: Integration.isEnabled, Integration.hint))
struct CleanIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    /// Megabytes of random data written to the root filesystem and to the volume, then deleted again.
    static let rootMegabytes = 200
    static let volumeMegabytes = 100

    /// Kilobytes the path occupies on the Mac (`du -sk`: blocks in use, not the sparse file's length); `nil`
    /// when the path is not there, as on a runtime that keeps its data elsewhere.
    private func kilobytesOnDisk(_ path: String) async -> Int? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let result = try? await ProcessRunner().run(["/usr/bin/du", "-sk", path], timeout: .seconds(60))
        return result?.stdoutText.split(whereSeparator: \.isWhitespace).first.flatMap { Int($0) }
    }

    /// What must be the same after `clean`: the kept files' checksums and the listing of both directories.
    private func contents(_ id: String) async throws -> String {
        try await Integration.shell(
            backend, id, "md5sum /root/keep.txt /data/keep.txt /root/dir/nested.bin && ls -la /root /root/dir /data")
    }

    @Test(.timeLimit(.minutes(10)))
    func cleanGivesSpaceBackAndDeletesNothing() async throws {
        guard await backend.supportsClean() else {
            // Before container 1.7: the command does not exist and the backend says so.
            let refused = await drain(backend.cleanContainers(["cd-it-reg-clean-none"]))
            guard case .unsupported = refused.error as? BackendError else {
                Issue.record("expected unsupported, got \(String(describing: refused.error))")
                return
            }
            return
        }
        let name = Integration.uniqueName("reg-clean")
        let volume = Integration.uniqueName("reg-clean-vol")
        try await backend.createVolume(name: volume, size: nil, journal: nil, labels: ["cd-it": "clean"])
        var spec = RunSpec(image: Integration.busyBoxImage)
        spec.name = name
        spec.command = ["sleep", "900"]
        spec.mounts = [.init(kind: .volume(name: volume), target: "/data")]
        do {
            for try await _ in backend.runContainer(spec) {}
            try await writeDeleteAndClean(name, volume: volume)
            try? await backend.deleteContainer(name, force: true)
            try? await backend.deleteVolume(volume)
        } catch {
            try? await backend.deleteContainer(name, force: true)
            try? await backend.deleteVolume(volume)
            throw error
        }
        #expect(try await !backend.listContainers(includeStopped: true).contains { $0.id == name })
        #expect(try await !backend.listVolumes().contains { $0.id == volume })
    }

    private func writeDeleteAndClean(_ name: String, volume: String) async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rootPath = "\(home)/Library/Application Support/com.apple.container/containers/\(name)"
        let volumePath = try await backend.inspectVolume(volume).configuration.source

        try await Integration.shell(
            backend, name,
            "echo keep-root > /root/keep.txt && echo keep-volume > /data/keep.txt && mkdir /root/dir && "
                + "dd if=/dev/urandom of=/root/dir/nested.bin bs=1M count=3 2>/dev/null && "
                + "dd if=/dev/urandom of=/root/big bs=1M count=\(Self.rootMegabytes) 2>/dev/null && "
                + "dd if=/dev/urandom of=/data/big bs=1M count=\(Self.volumeMegabytes) 2>/dev/null && sync")
        try await Integration.shell(backend, name, "rm /root/big /data/big && sync")
        let before = try await contents(name)
        let rootBefore = await kilobytesOnDisk(rootPath)
        let volumeBefore = await kilobytesOnDisk(volumePath)

        let cleaned = await drain(backend.cleanContainers([name]))
        #expect(cleaned.error == nil, "\(String(describing: cleaned.error))")
        #expect(cleaned.lines.map(\.text) == [name])  // the CLI prints the id of what it cleaned

        // Nothing inside changed, the container kept running, the volume is still there.
        #expect(try await contents(name) == before)
        #expect(try await backend.inspectContainer(name).isRunning)
        #expect(try await backend.listVolumes().contains { $0.id == volume })

        // The deleted files' blocks went back to the Mac. Measured only where the runtime keeps its data in the
        // usual place; at least half of what was written and deleted must be gone from each.
        if let rootBefore, let rootAfter = await kilobytesOnDisk(rootPath) {
            #expect(
                rootBefore - rootAfter > Self.rootMegabytes * 512, "root filesystem: \(rootBefore) → \(rootAfter) KB")
        }
        if let volumeBefore, let volumeAfter = await kilobytesOnDisk(volumePath) {
            #expect(
                volumeBefore - volumeAfter > Self.volumeMegabytes * 512, "volume: \(volumeBefore) → \(volumeAfter) KB")
        }

        // A second run is harmless. An unknown container is "not found"; the known one is cleaned all the same.
        #expect(await drain(backend.cleanContainers([name])).error == nil)
        let ghost = Integration.uniqueName("reg-clean-ghost")
        let mixed = await drain(backend.cleanContainers([ghost, name]))
        #expect(mixed.error as? BackendError == .notFound(kind: "container", id: ghost))
        #expect(mixed.lines.contains { $0.text == name })
        #expect(try await contents(name) == before)

        // A stopped container cannot be cleaned, and the error says what to do.
        try await backend.stopContainer(name, timeoutSeconds: 1, signal: nil)
        let stopped = await drain(backend.cleanContainers([name]))
        let text = (stopped.error as? BackendError)?.errorDescription ?? ""
        #expect(text.hasPrefix("Disk space can only be reclaimed from a running container."), "\(text)")
    }
}
