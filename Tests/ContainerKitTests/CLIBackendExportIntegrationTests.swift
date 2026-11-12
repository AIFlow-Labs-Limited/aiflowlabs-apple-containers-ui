import Foundation
import Testing

@testable import ContainerKit

/// Stopped containers, Export Filesystem and `commit` against the real `container` CLI. Creates only
/// `cd-it-…` containers and temporary folders, and removes them again.
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@Suite("CLIBackend Export Integration", .serialized, .enabled(if: Integration.isEnabled, Integration.hint))
struct CLIBackendExportIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    static let images = CLIBackendFilesIntegrationTests.images

    // MARK: Stopped containers

    @Test func stoppedContainerRefusesFilesButExports() async throws {
        let folder = try Integration.makeTemporaryFolder("stopped")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Integration.withContainer(backend) { id in
            try await Integration.shell(backend, id, "mkdir /keep && printf kept > '/keep/marker file'")
            try await backend.stopContainer(id, timeoutSeconds: 1, signal: nil)
            let notRunning = "container \(id) is not running"

            let list = await Integration.backendError { _ = try await backend.listDirectory(id, path: "/", limit: 10) }
            guard case .commandFailed(_, 1, let listMessage) = list else {
                Issue.record("expected commandFailed, got \(String(describing: list))")
                return
            }
            #expect(listMessage == notRunning)

            let read = await Integration.backendError {
                _ = try await backend.readFile(id, path: "/etc/hostname", maxBytes: 10)
            }
            guard case .commandFailed(_, 1, let readMessage) = read else {
                Issue.record("expected commandFailed, got \(String(describing: read))")
                return
            }
            #expect(readMessage == notRunning)

            let local = folder.appending(path: "marker")
            let out = await Integration.backendError {
                try await backend.copyOut(id, path: "/keep/marker file", to: local.path(percentEncoded: false))
            }
            guard case .commandFailed(_, 1, let outMessage) = out else {
                Issue.record("expected commandFailed, got \(String(describing: out))")
                return
            }
            #expect(outMessage.contains(notRunning))
            #expect(!FileManager.default.fileExists(atPath: local.path(percentEncoded: false)))

            try Data("x".utf8).write(to: local)
            let into = await Integration.backendError {
                try await backend.copyIn(id, localPath: local.path(percentEncoded: false), to: "/keep/x")
            }
            guard case .commandFailed(_, 1, let intoMessage) = into else {
                Issue.record("expected commandFailed, got \(String(describing: into))")
                return
            }
            #expect(intoMessage.contains(notRunning))

            // Export is what the Files tab offers for a stopped container.
            let tar = folder.appending(path: "stopped export.tar")
            try await backend.exportContainer(id, to: tar.path(percentEncoded: false))
            let entries = try Self.tarEntries(tar)
            #expect(entries.contains("keep/marker file"))
            #expect(entries.contains("etc/passwd"))
        }
    }

    @Test(arguments: images)
    func exportsARunningContainerAsATar(image: String) async throws {
        let folder = try Integration.makeTemporaryFolder("export")
        defer { try? FileManager.default.removeItem(at: folder) }
        try await Integration.withContainer(backend, image: image) { id in
            try await Integration.shell(backend, id, "mkdir /keep && printf kept > '/keep/marker file' && sync")
            let tar = folder.appending(path: "running export.tar")
            try await backend.exportContainer(id, to: tar.path(percentEncoded: false))
            let entries = try Self.tarEntries(tar)
            #expect(entries.count > 100)
            #expect(entries.contains("etc/passwd"))
            #expect(entries.contains("keep/marker file"))
            #expect(try Self.tarFile(tar, "keep/marker file") == Data("kept".utf8))
        }
        let ghost = Integration.uniqueName("ghost")
        let tar = folder.appending(path: "ghost.tar")
        let missing = await Integration.backendError {
            try await backend.exportContainer(ghost, to: tar.path(percentEncoded: false))
        }
        #expect(missing == .notFound(kind: "container", id: ghost))
    }

    // MARK: Commit

    @Test func commitIsReportedAsUnsupportedWhereTheCLILacksIt() async throws {
        let version = await backend.clientVersion() ?? ""
        let supported = await backend.supportsCommit()
        if version.hasPrefix("1.5.") { #expect(!supported, "container 1.5 has no `commit`") }
        #expect(await backend.supportsCommit() == supported)  // cached answer agrees
        guard !supported else { return }
        try await Integration.withContainer(backend) { id in
            let reference = "\(Integration.uniqueName("img")):latest"
            let failure = await Integration.backendError {
                for try await _ in backend.commitContainer(id, reference: reference) {}
            }
            guard case .unsupported(let feature, let reason) = failure else {
                Issue.record("expected unsupported, got \(String(describing: failure))")
                return
            }
            #expect(feature == "Save as Image")
            #expect(reason.contains("1.6"))
            let images = try await backend.listImages()
            #expect(!images.contains { $0.reference.contains(reference) })
        }
    }

    // MARK: Helpers

    /// Runs `/usr/bin/tar` and returns its stdout. Fails the test when `tar` rejects the archive.
    private static func tar(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/tar")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(
            process.terminationStatus == 0, "tar \(arguments) failed: \(String(decoding: errors, as: UTF8.self))")
        return data
    }

    /// Entry names of a tar archive without a leading `./` or trailing `/`.
    static func tarEntries(_ archive: URL) throws -> Set<String> {
        let listing = String(decoding: try tar(["-tf", archive.path(percentEncoded: false)]), as: UTF8.self)
        return Set(
            listing.split(separator: "\n").map { line in
                var name = String(line)
                if name.hasPrefix("./") { name.removeFirst(2) }
                while name.hasSuffix("/") { name.removeLast() }
                return name
            })
    }

    /// Contents of one member of a tar archive.
    static func tarFile(_ archive: URL, _ member: String) throws -> Data {
        try tar(["-xOf", archive.path(percentEncoded: false), member])
    }
}
