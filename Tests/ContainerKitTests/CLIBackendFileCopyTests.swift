import ContainerKitMock
import Foundation
import Synchronization
import Testing

@testable import ContainerKit

/// argv and behaviour of `copyIn` / `copyOut`, through a recording runner. What the real CLI does is covered by
/// `CLIBackendFileCopyIntegrationTests`.
@Suite("CLIBackend file copy")
struct CLIBackendFileCopyTests {
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
        let uploaded = UploadedPaths()
        let runner = RecordingRunner { arguments in
            if arguments.count == 5, arguments[3].hasSuffix("/payload") {
                staged.value.withLock { $0 = try? String(contentsOfFile: arguments[3], encoding: .utf8) }
            }
            // `test -e` inside the container: only what has been copied in exists.
            if arguments.dropFirst().first == "copy" { uploaded.value.withLock { $0.insert(arguments[4]) } }
            guard let flag = arguments.firstIndex(of: "-e") else { return ProcessResult() }
            let exists = uploaded.value.withLock { $0.contains("web:" + arguments[flag + 1]) }
            return ProcessResult(exitCode: exists ? 0 : 1, stdout: "", stderr: "")
        }
        let backend = try CLIBackend.recording(runner)
        try await backend.copyIn("web", localPath: plain, to: "/app/my file.txt")
        try await backend.copyIn("web", localPath: colon, to: "/app/shot.png")
        let probe = ["exec", "--", "web", "test", "-e", "/app/my file.txt", "-o", "-L", "/app/my file.txt"]
        #expect(runner.commands[0] == probe)  // does it exist already?
        #expect(runner.commands[1].first == "inspect")  // is it on a mount?
        #expect(
            runner.commands[2] == ["copy", "--", URL(filePath: plain).standardizedFileURL.path, "web:/app/my file.txt"])
        #expect(runner.commands[3] == probe)  // did it arrive?
        let copies = runner.commands.filter { $0.first == "copy" }
        #expect(copies.count == 2)
        #expect(copies[1][3] == "web:/app/shot.png")
        #expect(!copies[1][2].contains(":"))
        #expect(staged.value.withLock { $0 } == "b")  // the staged copy held the file's contents

        // Container paths with a colon cannot be addressed by `container cp` at all.
        await #expect(throws: BackendError.self) { try await backend.copyIn("web", localPath: plain, to: "/app/a:b") }
        await #expect(throws: BackendError.self) { try await backend.copyOut("web", path: "/app/a:b", to: plain) }
        await #expect(throws: BackendError.self) {
            try await backend.copyIn("web", localPath: plain + ".missing", to: "/app/x")
        }
        #expect(runner.commands.count == 8)
    }

    /// `container cp` nests into an existing directory, decomposes accented names and mangles non-ASCII names
    /// inside folders (CLI 1.5.0), so those uploads go through a temporary name and `mv`.
    @Test func copyInReplacesExistingItemsAndKeepsNames() async throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "cd-in-\(UUID().uuidString)")
        let folder = workspace.appending(path: "site")
        try FileManager.default.createDirectory(
            at: folder.appending(path: "caf\u{E9}"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try Data("a".utf8).write(to: folder.appending(path: "caf\u{E9}/men\u{FC}.txt"))
        try Data("b".utf8).write(to: folder.appending(path: "plain.txt"))
        let plain = folder.appending(path: "plain.txt").path(percentEncoded: false)

        // Existing destination: upload next to it, move the old one aside, move the new one in, remove the old.
        let existing = RecordingRunner()
        try await CLIBackend.recording(existing).copyIn("web", localPath: plain, to: "/app/plain.txt")
        let swap = existing.commands.filter { $0.first != "inspect" }
        #expect(swap.count == 5)
        let temporary = try #require(swap[1].last?.dropFirst("web:".count)).description
        #expect(temporary.hasPrefix("/app/.cd-upload-"))
        #expect(swap[1] == ["copy", "--", plain, "web:\(temporary)"])
        let aside = try #require(swap[2].last)
        #expect(aside.hasPrefix("/app/plain.txt.cd-replaced-"))
        #expect(swap[2] == ["exec", "--", "web", "mv", "--", "/app/plain.txt", aside])
        #expect(swap[3] == ["exec", "--", "web", "mv", "--", temporary, "/app/plain.txt"])
        #expect(swap[4] == ["exec", "--", "web", "rm", "-rf", "--", aside])

        // A system directory is never moved aside.
        let refused = RecordingRunner()
        await #expect(throws: BackendError.self) {
            try await CLIBackend.recording(refused).copyIn("web", localPath: plain, to: "/etc")
        }
        #expect(!refused.commands.contains { $0.first == "copy" || $0.contains("mv") })

        let fresh = RecordingRunner { arguments in
            arguments.contains("test") ? ProcessResult(exitCode: 1, stdout: "", stderr: "") : ProcessResult()
        }
        let backend = try CLIBackend.recording(fresh)
        // A precomposed name in the destination: `cp` would store it decomposed, `mv` keeps the bytes.
        try await backend.copyIn("web", localPath: plain, to: "/app/caf\u{E9}.txt")
        let exact = fresh.commands.filter { $0.first != "inspect" }
        #expect(exact.count == 3)
        #expect(exact[1][3].hasPrefix("web:/app/.cd-upload-"))
        // …and because `Process` would decompose the argument too, the `mv` travels as printf escapes.
        #expect(Array(exact[2].prefix(7)) == ["exec", "--", "web", "sh", "-c", CLIBackend.byteExactScript, "sh"])
        #expect(exact[2].last == #"/app/caf\303\251.txt"#)

        // Non-ASCII names inside a folder travel as placeholders and are renamed back, contents first.
        try await backend.copyIn("web", localPath: folder.path(percentEncoded: false), to: "/app/site")
        let upload = Array(fresh.commands.filter { $0.first != "inspect" }.dropFirst(3))
        #expect(upload.count == 4)
        #expect(upload[1][2].hasSuffix("/payload"))
        let uploaded = try #require(upload[1].last?.dropFirst("web:".count)).description
        // exec -- web sh -c DECODE sh | sh -c RENAME sh FROM TO FROM TO (all printf-escaped, so ASCII)
        let rename = upload[2]
        #expect(Array(rename.prefix(7)) == ["exec", "--", "web", "sh", "-c", CLIBackend.byteExactScript, "sh"])
        #expect(Array(rename[7...9]) == ["sh", "\\055c", rename[9]])
        let pairs = Array(rename.dropFirst(11))
        #expect(pairs.count == 4)
        #expect(rename.allSatisfy { $0.unicodeScalars.allSatisfy(\.isASCII) })
        #expect(pairs.allSatisfy { $0.hasPrefix(uploaded + "/") })
        #expect(pairs[0].hasPrefix(pairs[2] + "/"))  // the file inside the folder is renamed before the folder
        #expect(pairs[1].hasSuffix(#"/men\303\274.txt"#))
        #expect(pairs[3] == uploaded + #"/caf\303\251"#)
        #expect(upload[3] == ["exec", "--", "web", "mv", "--", uploaded, "/app/site"])
    }

    /// A precomposed name cannot be found by `container cp`; it is copied through an ASCII link.
    @Test func copyOutReachesPrecomposedNamesThroughALink() async throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "cd-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = RecordingRunner { arguments in
            if arguments.dropFirst().first == "copy", let staged = arguments.last {
                FileManager.default.createFile(atPath: staged, contents: Data("menu".utf8))
            }
            return ProcessResult()
        }
        let destination = workspace.appending(path: "menu.txt").path(percentEncoded: false)
        try await CLIBackend.recording(runner).copyOut("web", path: "/app/caf\u{E9}/menu.txt", to: destination)
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "menu")
        // The first command asks whether the path exists at all; then link, copy, remove the link.
        #expect(runner.commands.count == 4)
        #expect(runner.commands.first?.contains("test") == true)
        let commands = Array(runner.commands.dropFirst())
        let alias = try #require(commands[0].last)
        #expect(alias.hasPrefix("/.cd-copy-"))
        #expect(
            Array(commands[0].dropFirst(7)) == ["ln", "\\055s", "\\055-", #"/app/caf\303\251/menu.txt"#, alias])
        #expect(commands[1][2] == "web:\(alias)")
        #expect(commands[2] == ["exec", "--", "web", "rm", "-rf", "--", alias])

        #expect(CLIBackend.isCopyAddressable("/app/plain file.txt"))
        #expect(CLIBackend.isCopyAddressable("/app/日本語"))
        #expect(CLIBackend.isCopyAddressable("/app/cafe\u{301}"))
        #expect(!CLIBackend.isCopyAddressable("/app/caf\u{E9}"))
    }

    /// Something on a volume is "not found" by `container cp`; it is copied to the root filesystem first.
    @Test func copyOutReachesMountsThroughACopyInTheRootFilesystem() async throws {
        let workspace = FileManager.default.temporaryDirectory.appending(path: "cd-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let runner = RecordingRunner { arguments in
            guard arguments.dropFirst().first == "copy", let staged = arguments.last else { return ProcessResult() }
            if arguments[3] == "web:/data/dump.sql" {
                return ProcessResult(
                    exitCode: 1, stdout: "",
                    stderr:
                        #"Error: failed to copy from container web (cause: "unknown: "notFound: "copy: path not found '/data/dump.sql'""")"#
                )
            }
            FileManager.default.createFile(atPath: staged, contents: Data("dump".utf8))
            return ProcessResult()
        }
        let destination = workspace.appending(path: "dump.sql").path(percentEncoded: false)
        try await CLIBackend.recording(runner).copyOut("web", path: "/data/dump.sql", to: destination)
        #expect(try String(contentsOfFile: destination, encoding: .utf8) == "dump")
        let commands = runner.commands
        #expect(commands.count == 5)
        #expect(commands[0][2] == "web:/data/dump.sql")
        #expect(commands[1] == ["exec", "--", "web", "test", "-e", "/data/dump.sql", "-o", "-L", "/data/dump.sql"])
        let temporary = try #require(commands[2].last)
        #expect(temporary.hasPrefix("/.cd-copy-"))
        #expect(commands[2] == ["exec", "--", "web", "cp", "-a", "--", "/data/dump.sql", temporary])
        #expect(commands[3][2] == "web:\(temporary)")
        #expect(commands[4] == ["exec", "--", "web", "rm", "-rf", "--", temporary])
    }
}

/// What the fake CLI saw at the staging path.
private final class StagedContents: Sendable {
    let value = Mutex<String?>(nil)
}

/// `ID:PATH` destinations a fake CLI has "copied" into the container.
private final class UploadedPaths: Sendable {
    let value = Mutex<Set<String>>([])
}
