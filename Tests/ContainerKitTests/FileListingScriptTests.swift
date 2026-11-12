import Foundation
import Testing

@testable import ContainerKit

/// Runs `FileListing.script` with real POSIX shells on this Mac against a temporary directory full of awkward
/// names. macOS has BSD `stat` (no `-c`), so the plain run exercises the `ls` fallback; a tiny `stat -c` shim
/// on `PATH` (translating to BSD `stat -f`) exercises the primary method end to end.
@Suite("File listing script")
struct FileListingScriptTests {
    static let oddNames = [
        "plain.txt", "with space.txt", "two\nlines", "-dash", "--", "*", "tab\there", "café — 日本語 🚀",
        "quote'single", "quote\"double", "$HOME", "`id`", "semi;colon", ".hidden", "..double", "trailing ",
    ]

    /// A directory with `oddNames`, a sub-directory, a link to it and a dangling link.
    static func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "cd-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in oddNames {
            let path = root.path(percentEncoded: false) + "/" + name
            #expect(FileManager.default.createFile(atPath: path, contents: Data(name.utf8)))
        }
        let base = root.path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: base + "/sub dir", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: base + "/to dir", withDestinationPath: "sub dir")
        try FileManager.default.createSymbolicLink(atPath: base + "/dangling", withDestinationPath: "/no/such target")
        return root
    }

    /// A directory holding a `stat` that understands `stat -c FORMAT -- FILE…` like GNU/BusyBox.
    static func makeStatShim() throws -> URL {
        let bin = FileManager.default.temporaryDirectory.appending(path: "cd-shim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let shim = """
            #!/bin/sh
            [ "$1" = "-c" ] || exit 2
            fmt=$2; shift 2
            [ "$1" = "--" ] && shift
            bsd=$(printf '%s' "$fmt" | sed -e 's/%f/%Xp/' -e 's/%s/%z/' -e 's/%Y/%m/' -e 's/%U/%Su/' -e 's/%G/%Sg/' -e 's/%n/%N/')
            exec /usr/bin/stat -f "$bsd" -- "$@"

            """
        let path = bin.appending(path: "stat").path(percentEncoded: false)
        try shim.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return bin
    }

    func run(
        shell: String, directory: String, limit: Int = 100, path: String? = nil
    ) async throws -> (ProcessResult, String) {
        let nonce = FileListing.makeNonce()
        let command = FileListing.command(nonce: nonce, path: directory, limit: limit)
        let environment = path.map { ["PATH": $0] } ?? [:]
        let result = try await ProcessRunner().run(
            [shell] + command.dropFirst(), stdin: nil, timeout: .seconds(20), environment: environment)
        return (result, nonce)
    }

    @Test(arguments: ["/bin/sh", "/bin/dash", "/bin/bash"])
    func statMethodListsEveryOddNameExactly(shell: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let root = try Self.makeFixture()
        let shim = try Self.makeStatShim()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: shim)
        }
        let directory = root.path(percentEncoded: false)
        let (result, nonce) = try await run(
            shell: shell, directory: directory, path: shim.path(percentEncoded: false) + ":/usr/bin:/bin")
        #expect(result.exitCode == 0, "stderr: \(result.stderrText)")
        let listing = try #require(FileListing.parse(result.stdout, nonce: nonce, path: directory, limit: 100))
        #expect(listing.method == .stat)
        #expect(!listing.isTruncated)
        #expect(Set(listing.entries.map(\.name)) == Set(Self.oddNames + ["sub dir", "to dir", "dangling"]))
        #expect(listing.entries.count == Self.oddNames.count + 3)
        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })
        // Sizes prove each record was matched to the right name (the file holds its own name).
        for name in Self.oddNames { #expect(byName[name]?.size == Int64(name.utf8.count), "\(name)") }
        #expect(byName["plain.txt"]?.kind == .file)
        #expect(byName["sub dir"]?.kind == .directory)
        #expect(byName["to dir"]?.kind == .symlink)
        #expect(byName["to dir"]?.linkTarget == "sub dir")
        #expect(byName["to dir"]?.linkPointsToDirectory == true)
        #expect(byName["dangling"]?.linkTarget == "/no/such target")
        #expect(byName["dangling"]?.linkPointsToDirectory == false)
        #expect(byName["plain.txt"]?.uid == Int(getuid()))
        let modified = try #require(byName["plain.txt"]?.modified)
        #expect(abs(modified.timeIntervalSinceNow) < 300)
    }

    @Test func statMethodReportsTruncation() async throws {
        let root = try Self.makeFixture()
        let shim = try Self.makeStatShim()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: shim)
        }
        let directory = root.path(percentEncoded: false)
        let (result, nonce) = try await run(
            shell: "/bin/sh", directory: directory, limit: 5, path: shim.path(percentEncoded: false) + ":/usr/bin:/bin")
        let listing = try #require(FileListing.parse(result.stdout, nonce: nonce, path: directory, limit: 5))
        #expect(listing.entries.count == 5)
        #expect(listing.isTruncated)
    }

    @Test func fallsBackToLsWithoutStatFormatSupport() async throws {
        let root = try Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.path(percentEncoded: false)
        // BSD stat has no `-c`, BSD ls no `--full-time`: the script must settle on `ls -lAn`.
        let (result, nonce) = try await run(shell: "/bin/sh", directory: directory, path: "/usr/bin:/bin")
        #expect(result.exitCode == 0, "stderr: \(result.stderrText)")
        let listing = try #require(FileListing.parse(result.stdout, nonce: nonce, path: directory, limit: 100))
        #expect(listing.method == .lsLong)
        let byName = Dictionary(listing.entries.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        // Everything except the name with a newline is exact, even through `ls`.
        for name in Self.oddNames where !name.contains("\n") {
            #expect(byName[name]?.size == Int64(name.utf8.count), "\(name)")
        }
        #expect(byName["sub dir"]?.kind == .directory)
        #expect(byName["to dir"]?.linkTarget == "sub dir")
        #expect(byName["."] == nil)
    }

    @Test func reportsMissingDirectoryAndMissingTools() async throws {
        let (missing, nonce) = try await run(shell: "/bin/sh", directory: "/no/such/dir-\(UUID().uuidString)")
        #expect(missing.exitCode == FileListing.missingExitCode)
        guard
            case .failure(let message) = FileListing.interpret(
                exitCode: missing.exitCode, stdout: missing.stdout, stderr: missing.stderrText, nonce: nonce,
                path: "/no/such/dir", limit: 10)
        else {
            Issue.record("expected a failure")
            return
        }
        #expect(message == "“/no/such/dir” does not exist.")

        let (file, fileNonce) = try await run(shell: "/bin/sh", directory: "/etc/hosts")
        #expect(file.exitCode == FileListing.notADirectoryExitCode)
        #expect(
            FileListing.interpret(
                exitCode: file.exitCode, stdout: file.stdout, stderr: file.stderrText, nonce: fileNonce,
                path: "/etc/hosts", limit: 10) == .failure(message: "“/etc/hosts” is not a directory."))

        // An empty PATH: neither stat nor ls can be found, but the shell itself runs.
        let empty = FileManager.default.temporaryDirectory.appending(path: "cd-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let (bare, bareNonce) = try await run(
            shell: "/bin/sh", directory: "/tmp", path: empty.path(percentEncoded: false))
        let outcome = FileListing.interpret(
            exitCode: bare.exitCode, stdout: bare.stdout, stderr: bare.stderrText, nonce: bareNonce, path: "/tmp",
            limit: 10)
        #expect(outcome == .listing(ContainerDirectoryListing(path: "/tmp", method: nil, unavailable: .noListingTool)))
    }
}
