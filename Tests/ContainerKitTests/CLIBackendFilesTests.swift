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

    @Test func precomposedArgumentsTravelAsPrintfEscapes() {
        #expect(
            CLIBackend.byteExact(["head", "-c", "4", "--", "/etc/my file"]) == [
                "head", "-c", "4", "--", "/etc/my file",
            ])
        #expect(CLIBackend.byteExact(["cat", "/日本語/cafe\u{301}"]) == ["cat", "/日本語/cafe\u{301}"])  // already decomposed
        #expect(
            CLIBackend.byteExact(["rm", "-rf", "--", "/a/caf\u{E9} 100%\\\n"])
                == [
                    "sh", "-c", CLIBackend.byteExactScript, "sh", "rm", #"\055rf"#, #"\055-"#,
                    #"/a/caf\303\251 100%%\\\012"#,
                ])
        #expect(CLIBackend.printfEscaped("\u{AC00}") == #"\352\260\200"#)  // a Hangul syllable
        #expect(CLIBackend.printfEscaped("") == "")
    }

    /// The decoding script, run for real through the shells an image is likely to have as `sh`.
    @Test(arguments: ["/bin/sh", "/bin/dash", "/bin/bash"])
    func printfEscapesDecodeToTheExactBytes(shell: String) async throws {
        let arguments = ["-n", "caf\u{E9} \u{AC00}", "new\nline\n", "100% \\x", "", "it's \"q\" $HOME `x`"]
        let command = CLIBackend.byteExact(["/usr/bin/printf", "%s|"] + arguments)
        #expect(command.first == "sh")
        let result = try await ProcessRunner().run(
            [shell] + command.dropFirst(), stdin: nil, timeout: .seconds(20), environment: [:])
        #expect(result.exitCode == 0, "\(result.stderrText)")
        #expect(result.stdout == Data(arguments.map { $0 + "|" }.joined().utf8))
    }

    @Test func mountsAndCommitFailuresAreRecognised() {
        let mounts = ["/data", "/var/lib/postgresql/data/"]
        #expect(CLIBackend.isOutsideRootFilesystem("/data/dump.sql", mounts: mounts))
        #expect(CLIBackend.isOutsideRootFilesystem("/data", mounts: mounts))
        #expect(CLIBackend.isOutsideRootFilesystem("/var/lib/postgresql/data/base", mounts: mounts))
        #expect(CLIBackend.isOutsideRootFilesystem("/dev/shm/x", mounts: []))
        #expect(!CLIBackend.isOutsideRootFilesystem("/database/x", mounts: mounts))
        #expect(!CLIBackend.isOutsideRootFilesystem("/var/lib/x", mounts: mounts))
        #expect(!CLIBackend.isOutsideRootFilesystem("/tmp/x", mounts: ["/"]))

        let unknown = BackendError.commandFailed(
            command: "container commit -- web img", exitCode: 64,
            message: "unknown command 'commit'\nIf 'commit' is a plugin, check that it exists under:")
        guard case BackendError.unsupported(let feature, _) = CLIBackend.commitFailure(unknown) else {
            Issue.record("expected unsupported")
            return
        }
        #expect(feature == "Save as Image")
        let other = BackendError.commandFailed(command: "c", exitCode: 1, message: "container web not found")
        #expect(CLIBackend.commitFailure(other) as? BackendError == other)
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
