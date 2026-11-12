import ContainerKitMock
import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// argv and behaviour of the Files tab and `commit` operations of `CLIBackend`, through a recording runner.
@Suite("CLIBackend files and commit")
struct CLIBackendFilesTests {
    @Test func listDirectoryRunsOneExecAndParsesIt() async throws {
        let runner = RecordingRunner { arguments in
            // argv: container exec -- web sh -c SCRIPT sh NONCE PATH LIMIT
            let nonce = arguments[8]
            return ProcessResult(
                stdout:
                    "\(nonce) S\n\(nonce) M stat\n\(nonce) E 41ed/4096/0/0/1700000000/root/root/my dir\n\(nonce) Z\n")
        }
        let backend = try CLIBackend.recording(runner)
        let listing = try await backend.listDirectory("web", path: "/var//lib/../log/", limit: 500)
        #expect(listing.path == "/var/log")
        #expect(listing.entries.map(\.name) == ["my dir"])
        #expect(runner.commands.count == 1)
        let argv = try #require(runner.commands.first)
        #expect(Array(argv.prefix(7)) == ["exec", "--", "web", "sh", "-c", FileListing.script, "sh"])
        #expect(argv[7].count == 16 && argv[7].allSatisfy { $0.isHexDigit })
        #expect(Array(argv.suffix(2)) == ["/var/log", "500"])
    }

    @Test func listDirectoryMapsShellLessImagesAndErrors() async throws {
        let noShell = try CLIBackend.recording(
            RecordingRunner { _ in
                ProcessResult(exitCode: 1, stdout: "", stderr: "Error: failed to find target executable sh")
            })
        let listing = try await noShell.listDirectory("web", path: "/", limit: 10)
        #expect(listing.unavailable == .noShell)
        #expect(listing.entries.isEmpty)

        let missing = try CLIBackend.recording(
            RecordingRunner { _ in
                ProcessResult(
                    exitCode: 66, stdout: "", stderr: "sh: cd: can't cd to /nope: No such file or directory\n")
            })
        do {
            _ = try await missing.listDirectory("web", path: "/nope", limit: 10)
            Issue.record("expected an error")
        } catch let BackendError.commandFailed(command, code, message) {
            #expect(code == 66)
            #expect(message == "sh: cd: can't cd to /nope: No such file or directory")
            #expect(command.hasPrefix("/usr/local/bin/container exec -- web sh -c "))
            #expect(command.hasSuffix(" /nope 10"))
        }

        let gone = try CLIBackend.recording(
            RecordingRunner { _ in ProcessResult(exitCode: 1, stdout: "", stderr: "Error: container web not found") })
        await #expect(throws: BackendError.notFound(kind: "container", id: "web")) {
            _ = try await gone.listDirectory("web", path: "/", limit: 10)
        }
        await #expect(throws: BackendError.self) { _ = try await gone.listDirectory("web", path: "relative", limit: 1) }
        await #expect(throws: BackendError.self) { _ = try await gone.listDirectory("-x", path: "/", limit: 1) }
    }

    @Test func fileCommandsArgv() async throws {
        let runner = RecordingRunner { arguments in
            arguments.contains("head") ? ProcessResult(stdout: Data([0x68, 0x69, 0x00, 0xFF, 0x21])) : ProcessResult()
        }
        let backend = try CLIBackend.recording(runner)
        let data = try await backend.readFile("web", path: "/etc/my file", maxBytes: 4)
        #expect(data == Data([0x68, 0x69, 0x00, 0xFF]))  // binary-safe, never more than maxBytes
        try await backend.makeDirectory("web", path: "/data/new folder")
        try await backend.moveItem("web", from: "/data/-a", to: "/data/b c")
        try await backend.deleteItem("web", path: "/data/b c")
        #expect(
            runner.commands == [
                ["exec", "--", "web", "head", "-c", "4", "--", "/etc/my file"],
                ["exec", "--", "web", "mkdir", "--", "/data/new folder"],
                ["exec", "--", "web", "mv", "--", "/data/-a", "/data/b c"],
                ["exec", "--", "web", "rm", "-rf", "--", "/data/b c"],
            ])
    }

    @Test func failedFileCommandCarriesTheExactCommand() async throws {
        let backend = try CLIBackend.recording(
            RecordingRunner { _ in
                ProcessResult(exitCode: 1, stdout: "", stderr: "mkdir: can't create directory '/x y': File exists\n")
            })
        await #expect(
            throws: BackendError.commandFailed(
                command: "/usr/local/bin/container exec -- web mkdir -- '/x y'", exitCode: 1,
                message: "mkdir: can't create directory '/x y': File exists")
        ) {
            try await backend.makeDirectory("web", path: "/x y")
        }
    }

    @Test func deleteRefusesCatastrophicTargetsBeforeRunning() async throws {
        let runner = RecordingRunner()
        let backend = try CLIBackend.recording(runner)
        for path in ["/", "//", "/etc", "/usr/", "/var/lib", "/a/../..", "relative"] {
            await #expect(throws: BackendError.self, "\(path)") { try await backend.deleteItem("web", path: path) }
        }
        await #expect(throws: BackendError.self) { try await backend.moveItem("web", from: "/", to: "/x") }
        #expect(runner.calls.isEmpty)
    }

    @Test func copyOutStagesThenMovesIntoPlace() async throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "cd-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // A destination the CLI could not address itself (colon), which already exists.
        let destination = workspace.appending(path: "notes 12:30.txt").path(percentEncoded: false)
        try Data("old".utf8).write(to: URL(filePath: destination))
        let runner = RecordingRunner { arguments in
            // Play the CLI: write the "copied" file to the staging path it was given.
            if arguments.dropFirst().first == "copy", let staged = arguments.last {
                FileManager.default.createFile(atPath: staged, contents: Data("new".utf8))
            }
            return ProcessResult()
        }
        let backend = try CLIBackend.recording(runner)
        try await backend.copyOut("web", path: "/etc/my hosts", to: destination)
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "new")
        let argv = try #require(runner.commands.first)
        #expect(Array(argv.prefix(3)) == ["copy", "--", "web:/etc/my hosts"])
        #expect(!argv[3].contains(":"))
        #expect(argv[3].hasSuffix("/payload"))
        // The staging directory is gone afterwards.
        #expect(!FileManager.default.fileExists(atPath: (argv[3] as NSString).deletingLastPathComponent))
    }

    @Test func copyOutFailureLeavesTheDestinationAlone() async throws {
        let destination = FileManager.default.temporaryDirectory.appending(path: "cd-keep-\(UUID().uuidString).txt")
        try Data("keep".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let failing = try CLIBackend.recording(
            RecordingRunner { _ in ProcessResult(exitCode: 1, stdout: "", stderr: "Error: container web is not running")
            })
        await #expect(throws: BackendError.self) {
            try await failing.copyOut("web", path: "/etc/hosts", to: destination.path(percentEncoded: false))
        }
        // A copy that "succeeds" without producing anything is reported, not silently accepted.
        let silent = try CLIBackend.recording(RecordingRunner { _ in ProcessResult() })
        await #expect(throws: BackendError.self) {
            try await silent.copyOut("web", path: "/etc/hosts", to: destination.path(percentEncoded: false))
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "keep")
    }

    @Test func copyInArgvAndColonHandling() async throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "cd-in-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let plain = workspace.appending(path: "my file.txt").path(percentEncoded: false)
        let colon = workspace.appending(path: "shot 12:30.png").path(percentEncoded: false)
        FileManager.default.createFile(atPath: plain, contents: Data("a".utf8))
        FileManager.default.createFile(atPath: colon, contents: Data("b".utf8))
        let staged = StagedContents()
        let runner = RecordingRunner { arguments in
            if arguments.count == 5, arguments[3].hasSuffix("/payload") {
                staged.value.withLock { $0 = try? String(contentsOfFile: arguments[3], encoding: .utf8) }
            }
            return ProcessResult()
        }
        let backend = try CLIBackend.recording(runner)
        try await backend.copyIn("web", localPath: plain, to: "/app/my file.txt")
        try await backend.copyIn("web", localPath: colon, to: "/app/shot.png")
        #expect(
            runner.commands[0] == ["copy", "--", URL(filePath: plain).standardizedFileURL.path, "web:/app/my file.txt"])
        #expect(runner.commands[1][3] == "web:/app/shot.png")
        #expect(!runner.commands[1][2].contains(":"))
        #expect(staged.value.withLock { $0 } == "b")  // the staged copy held the file's contents

        // Container paths with a colon cannot be addressed by `container cp` at all.
        await #expect(throws: BackendError.self) { try await backend.copyIn("web", localPath: plain, to: "/app/a:b") }
        await #expect(throws: BackendError.self) { try await backend.copyOut("web", path: "/app/a:b", to: plain) }
        await #expect(throws: BackendError.self) {
            try await backend.copyIn("web", localPath: plain + ".missing", to: "/app/x")
        }
        #expect(runner.commands.count == 2)
    }

    @Test func commitArgvAndValidation() async throws {
        let runner = RecordingRunner(streamLines: [OutputLine("Loading images")])
        let backend = try CLIBackend.recording(runner)
        let result = await drain(backend.commitContainer("web", reference: "ghcr.io/me/web:1.0"))
        #expect(result.error == nil)
        #expect(result.lines.map(\.text) == ["Loading images"])
        #expect(runner.commands == [["commit", "--", "web", "ghcr.io/me/web:1.0"]])
        #expect(runner.calls[0].streamed)
        #expect(await drain(backend.commitContainer("web", reference: "--help")).error != nil)
        #expect(await drain(backend.commitContainer("-a", reference: "x:1")).error != nil)
        #expect(await drain(backend.commitContainer("web", reference: "")).error != nil)
        #expect(runner.calls.count == 1)
        #expect(CLIBackend.commitCommandPreview("my web", reference: "x:1") == "container commit -- 'my web' x:1")
    }

    @Test func commitProbeIsCached() async throws {
        // CLI 1.5.0: `commit` is looked up as a plugin and fails with usage exit code 64.
        let old = RecordingRunner { _ in
            ProcessResult(
                exitCode: 64, stdout: "",
                stderr: "Error: Plugins are unavailable. Start the container system services and retry")
        }
        let oldBackend = try CLIBackend.recording(old)
        #expect(await oldBackend.supportsCommit() == false)
        #expect(await oldBackend.supportsCommit() == false)
        #expect(old.commands == [["commit", "--help"]])  // one probe, no `system status` follow-up

        let new = RecordingRunner { _ in
            ProcessResult(stdout: "OVERVIEW: Create a new image from a container's filesystem\n")
        }
        let newBackend = try CLIBackend.recording(new)
        #expect(await newBackend.supportsCommit())
        #expect(await newBackend.supportsCommit())
        #expect(new.commands == [["commit", "--help"]])
    }

    @Test func commitProbeDoesNotCacheWhenItCouldNotRun() async throws {
        let runner = FlakyRunner()
        let backend = try CLIBackend(executable: "/usr/local/bin/container", runner: runner)
        #expect(await backend.supportsCommit() == false)  // the probe itself failed to launch
        #expect(await backend.supportsCommit())  // asked again, and now it answers
        #expect(runner.count == 2)
    }
}

/// What the fake CLI saw at the staging path.
private final class StagedContents: Sendable {
    let value = Mutex<String?>(nil)
}

/// Fails the first `run`, succeeds afterwards.
private final class FlakyRunner: CommandRunning {
    private let calls = Mutex(0)
    var count: Int { calls.withLock { $0 } }

    func run(
        _ arguments: [String], stdin: Data?, timeout: Duration?, environment: [String: String]
    ) async throws -> ProcessResult {
        let call = calls.withLock { value -> Int in
            value += 1
            return value
        }
        if call == 1 { throw BackendError.other("could not launch") }
        return ProcessResult()
    }

    func stream(_ arguments: [String], environment: [String: String]) -> LineStream {
        AsyncThrowingStream { $0.finish() }
    }
}
