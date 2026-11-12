import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

/// `ContainerPath` helpers and the mock backend's fake filesystem.
@Suite("Container paths and mock files")
struct MockFilesTests {
    @Test func normalizeAndNavigate() {
        #expect(ContainerPath.normalize("/a//b/./c/") == "/a/b/c")
        #expect(ContainerPath.normalize("/a/../../b") == "/b")
        #expect(ContainerPath.normalize("/") == "/")
        #expect(ContainerPath.normalize("") == "/")
        #expect(ContainerPath.normalize("log", relativeTo: "/var") == "/var/log")
        #expect(ContainerPath.normalize("../etc", relativeTo: "/var/log") == "/var/etc")
        #expect(ContainerPath.normalize("/abs", relativeTo: "/var") == "/abs")
        #expect(ContainerPath.parent(of: "/var/log") == "/var")
        #expect(ContainerPath.parent(of: "/var") == "/")
        #expect(ContainerPath.parent(of: "/") == "/")
        #expect(ContainerPath.name(of: "/var/my log") == "my log")
        #expect(ContainerPath.name(of: "/") == "")
        #expect(ContainerPath.join("/", "etc") == "/etc")
        #expect(ContainerPath.join("/etc", "hosts") == "/etc/hosts")
        #expect(ContainerPath.ancestors(of: "/var/log") == ["/", "/var", "/var/log"])
        #expect(ContainerPath.isSameOrInside("/var/log/x", "/var/log"))
        #expect(!ContainerPath.isSameOrInside("/var/logs", "/var/log"))
    }

    @Test func nameValidation() {
        #expect(ContainerPath.nameProblem("notes.txt") == nil)
        #expect(ContainerPath.nameProblem("with space — ünï") == nil)
        #expect(ContainerPath.nameProblem("") != nil)
        #expect(ContainerPath.nameProblem(".") != nil)
        #expect(ContainerPath.nameProblem("..") != nil)
        #expect(ContainerPath.nameProblem("a/b") != nil)
        #expect(ContainerPath.nameProblem(String(repeating: "x", count: 256)) != nil)
    }

    @Test func deletionRefusals() {
        for path in ["/", "/etc", "/usr", "/usr/bin", "/var/lib", "/home", "/tmp", "relative", "/a/../b", "/a/"] {
            #expect(ContainerPath.deletionRefusal(path) != nil, "\(path)")
        }
        for path in ["/app", "/etc/hosts", "/var/lib/postgresql", "/tmp/x", "/home/me/file"] {
            #expect(ContainerPath.deletionRefusal(path) == nil, "\(path)")
        }
        let mounts = ["/var/lib/postgresql/data/", "/"]
        #expect(
            ContainerPath.deletionRefusal("/var/lib/postgresql/data", mountPoints: mounts)?.contains("mount point")
                == true)
        #expect(
            ContainerPath.deletionRefusal("/var/lib/postgresql", mountPoints: mounts)?.contains("contains the mount")
                == true)
        #expect(ContainerPath.deletionRefusal("/var/lib/postgresql/data/base", mountPoints: mounts) == nil)
    }

    // MARK: MockBackend

    func backend() async -> MockBackend {
        let backend = MockBackend()
        await backend.setLatency(.zero)
        return backend
    }

    @Test func mockServesABelievableFilesystem() async throws {
        let backend = await backend()
        let root = try await backend.listDirectory("db", path: "/", limit: 2000)
        #expect(root.method == .stat)
        #expect(
            Set(["bin", "etc", "usr", "var", "tmp", "root", ".dockerenv"]).isSubset(of: Set(root.entries.map(\.name))))
        let data = try await backend.listDirectory("db", path: "/var/lib/postgresql/data", limit: 2000)
        #expect(data.entries.contains { $0.name == "PG_VERSION" && $0.owner == "postgres" })
        // /var/run is a link to /run: listed as a browsable link, and listing through it works.
        let varEntries = try await backend.listDirectory("db", path: "/var", limit: 2000).entries
        let run = try #require(varEntries.first { $0.name == "run" })
        #expect(run.kind == .symlink && run.linkTarget == "/run" && run.linkPointsToDirectory)
        #expect(
            try await backend.listDirectory("db", path: "/var/run", limit: 10).entries.map(\.name) == ["postgresql"])
        let text = try await backend.readFile("db", path: "/var/lib/postgresql/data/PG_VERSION", maxBytes: 100)
        #expect(String(decoding: text, as: UTF8.self) == "16\n")
        #expect(try await backend.readFile("db", path: "/etc/os-release", maxBytes: 4).count == 4)
    }

    @Test func mockTruncatesHugeDirectoriesAndReportsErrors() async throws {
        let backend = await backend()
        let events = try await backend.listDirectory("api", path: "/app/data/events", limit: 2000)
        #expect(events.entries.count == 2000)
        #expect(events.isTruncated)
        await #expect(throws: BackendError.self) {
            _ = try await backend.listDirectory("api", path: "/nope", limit: 10)
        }
        await #expect(throws: BackendError.self) {
            _ = try await backend.listDirectory("api", path: "/app/app.py", limit: 10)
        }
        // Stopped container: the same error the CLI gives, with the command.
        do {
            _ = try await backend.listDirectory("old-job", path: "/", limit: 10)
            Issue.record("expected an error")
        } catch let BackendError.commandFailed(command, _, message) {
            #expect(message == "container old-job is not running")
            #expect(command.hasPrefix("container exec -- old-job "))
        }
        await #expect(throws: BackendError.notFound(kind: "container", id: "ghost")) {
            _ = try await backend.listDirectory("ghost", path: "/", limit: 10)
        }
    }

    @Test func mockShellLessImage() async throws {
        let backend = await backend()
        var distroless = MockFileSystem()
        distroless.hasShell = false
        distroless.file("/app/server", size: 1_000_000, mode: 0o755)
        await backend.setFileSystem(distroless, for: "api")
        let listing = try await backend.listDirectory("api", path: "/", limit: 10)
        #expect(listing.unavailable == .noShell)
        #expect(listing.entries.isEmpty)
        await #expect(throws: BackendError.self) { try await backend.makeDirectory("api", path: "/x") }
    }

    @Test func mockMutations() async throws {
        let backend = await backend()
        func names(_ path: String) async throws -> [String] {
            try await backend.listDirectory("api", path: path, limit: 5000).entries.map(\.name)
        }
        try await backend.makeDirectory("api", path: "/app/new folder")
        #expect(try await names("/app").contains("new folder"))
        await #expect(throws: BackendError.self) { try await backend.makeDirectory("api", path: "/app/new folder") }
        await #expect(throws: BackendError.self) { try await backend.makeDirectory("api", path: "/missing/child") }

        try await backend.moveItem("api", from: "/app/static", to: "/app/assets")
        #expect(try await names("/app/assets") == ["logo.png"])
        #expect(try await !names("/app").contains("static"))
        await #expect(throws: BackendError.self) {
            try await backend.moveItem("api", from: "/app/README.md", to: "/app/app.py")
        }

        try await backend.deleteItem("api", path: "/app/data")
        #expect(try await !names("/app").contains("data"))
        await #expect(throws: BackendError.self) {
            _ = try await backend.listDirectory("api", path: "/app/data/events", limit: 1)
        }
        await #expect(throws: BackendError.other("The root directory cannot be deleted.")) {
            try await backend.deleteItem("api", path: "/")
        }
    }

    @Test func mockCopyOutAndIn() async throws {
        let backend = await backend()
        let workspace = FileManager.default.temporaryDirectory.appending(path: "cd-mock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let file = workspace.appending(path: "requirements.txt").path(percentEncoded: false)
        try await backend.copyOut("api", path: "/app/requirements.txt", to: file)
        #expect(try String(contentsOfFile: file, encoding: .utf8).hasPrefix("fastapi=="))
        let folder = workspace.appending(path: "docs").path(percentEncoded: false)
        try await backend.copyOut("api", path: "/app/docs", to: folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder) == ["café menu — naïve.md"])

        let upload = workspace.appending(path: "hello world.txt").path(percentEncoded: false)
        try Data("hi".utf8).write(to: URL(filePath: upload))
        try await backend.copyIn("api", localPath: upload, to: "/app/hello world.txt")
        #expect(try await backend.readFile("api", path: "/app/hello world.txt", maxBytes: 10) == Data("hi".utf8))
        try await backend.copyIn("api", localPath: workspace.path(percentEncoded: false), to: "/app/uploaded")
        let uploaded = try await backend.listDirectory("api", path: "/app/uploaded", limit: 100).entries
        #expect(Set(uploaded.map(\.name)) == ["requirements.txt", "docs", "hello world.txt"])
        await #expect(throws: BackendError.self) { try await backend.copyOut("old-job", path: "/etc/hosts", to: file) }
        await #expect(throws: BackendError.self) {
            try await backend.copyIn("api", localPath: file + ".none", to: "/x")
        }
    }

    @Test func mockCommit() async throws {
        let backend = await backend()
        #expect(await backend.supportsCommit())
        let before = try await backend.listImages().count
        let result = await drain(backend.commitContainer("old-job", reference: "old-job:snapshot"))
        #expect(result.error == nil)
        #expect(result.lines.last?.text == "old-job:snapshot")
        let images = try await backend.listImages()
        #expect(images.count == before + 1)
        #expect(images.contains { $0.reference == "old-job:snapshot" })

        let missing = await drain(backend.commitContainer("ghost", reference: "x:1"))
        #expect(missing.error as? BackendError == .notFound(kind: "container", id: "ghost"))

        await backend.setCommitSupported(false)
        #expect(await backend.supportsCommit() == false)
        let refused = await drain(backend.commitContainer("old-job", reference: "y:1"))
        guard case .unsupported = refused.error as? BackendError else {
            Issue.record("expected unsupported, got \(String(describing: refused.error))")
            return
        }
    }
}

extension MockBackend {
    func setCommitSupported(_ value: Bool) { commitSupported = value }
}
