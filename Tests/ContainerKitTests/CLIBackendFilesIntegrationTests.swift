import Foundation
import Testing

@testable import ContainerKit

/// The Files tab's backend calls against the real `container` CLI, in a BusyBox container (`alpine`) and a GNU
/// coreutils one (`python:3.11-slim`). Both images must be local. Creates only `cd-it-…` containers and
/// temporary folders, and removes them again.
/// Run with: `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
@Suite("CLIBackend Files Integration", .serialized, .enabled(if: Integration.isEnabled, Integration.hint))
struct CLIBackendFilesIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    static let images = [Integration.busyBoxImage, Integration.gnuImage]

    /// Builds `/work` with names that break naive parsers. Raw string: the script is passed to `sh -c` verbatim.
    static let awkwardScript = #"""
        set -e
        mkdir -p /work/sub && cd /work
        printf 'hi\n' > 'a b.txt'
        printf x > ./-dash
        printf n > 'new
        line'
        ln -s /etc/passwd link
        ln -s /etc dirlink
        ln -s /nowhere dangling
        ln -s 'tar
        get' nltarget
        printf u > 'unicodé-日本語'
        printf h > .hidden
        printf h > ..twodots
        printf q > "it's \"quoted\""
        printf t > "$(printf 'tab\there')"
        printf a > 'arrow -> name'
        printf s > 'trailing space '
        printf s > '*star'
        printf c > "$(printf 'cr\r')"
        printf deep > sub/deep.txt
        mkfifo pipe
        printf 1234567 > sized
        chown 1234:5678 sized
        chmod 4755 sized
        touch -d @1700000000 sized
        """#

    static let awkwardNames: Set<String> = [
        "a b.txt", "-dash", "new\nline", "link", "dirlink", "dangling", "nltarget", "unicodé-日本語", ".hidden",
        "..twodots", "it's \"quoted\"", "tab\there", "arrow -> name", "trailing space ", "*star", "cr\r", "sub",
        "pipe", "sized",
    ]

    // MARK: Listing

    @Test(arguments: images)
    func listsRootAndEtc(image: String) async throws {
        try await Integration.withContainer(backend, image: image) { id in
            let root = try await backend.listDirectory(id, path: "/", limit: 1000)
            #expect(root.method == .stat)
            #expect(root.unavailable == nil)
            #expect(!root.isTruncated)
            #expect(root.path == "/")
            let byName = Dictionary(uniqueKeysWithValues: root.entries.map { ($0.name, $0) })
            for name in ["etc", "proc", "tmp", "usr"] { #expect(byName[name]?.kind == .directory, "\(name)") }
            #expect(byName["bin"]?.isBrowsable == true)  // a directory on Alpine, a link to usr/bin on Debian
            #expect(byName["etc"]?.owner == "root")
            #expect(byName["etc"]?.uid == 0)
            #expect(byName["tmp"]?.permissions == 0o1777)

            let etc = try await backend.listDirectory(id, path: "/etc/", limit: 1000)
            #expect(etc.path == "/etc")
            let passwd = try #require(etc.entries.first { $0.name == "passwd" })
            #expect(passwd.kind == .file)
            #expect(passwd.size > 0)
            #expect(passwd.modified != nil)
            #expect(etc.entries.contains { $0.name == "hostname" || $0.name == "hosts" })
        }
    }

    @Test(arguments: images)
    func listsAwkwardNamesExactly(image: String) async throws {
        try await Integration.withContainer(backend, image: image) { id in
            try await Integration.shell(backend, id, Self.awkwardScript)
            let listing = try await backend.listDirectory(id, path: "/work", limit: 1000)
            #expect(listing.method == .stat)
            #expect(Set(listing.entries.map(\.name)) == Self.awkwardNames)
            #expect(listing.entries.count == Self.awkwardNames.count)
            let byName = Dictionary(listing.entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

            #expect(byName["a b.txt"]?.kind == .file)
            #expect(byName["a b.txt"]?.size == 3)
            #expect(byName["-dash"]?.size == 1)
            #expect(byName["new\nline"]?.kind == .file)
            #expect(byName["sub"]?.kind == .directory)
            #expect(byName["pipe"]?.kind == .fifo)
            #expect(byName[".hidden"]?.isHidden == true)
            #expect(byName["..twodots"]?.isHidden == true)
            #expect(byName["a b.txt"]?.isHidden == false)

            let link = try #require(byName["link"])
            #expect(link.kind == .symlink)
            #expect(link.linkTarget == "/etc/passwd")
            #expect(!link.linkPointsToDirectory)
            #expect(!link.isBrowsable)
            let dirlink = try #require(byName["dirlink"])
            #expect(dirlink.linkTarget == "/etc")
            #expect(dirlink.isBrowsable)
            let dangling = try #require(byName["dangling"])
            #expect(dangling.kind == .symlink)
            #expect(dangling.linkTarget == "/nowhere")
            #expect(!dangling.isBrowsable)
            #expect(byName["nltarget"]?.linkTarget == "tar\nget")

            let sized = try #require(byName["sized"])
            #expect(sized.size == 7)
            #expect(sized.permissions == 0o4755)
            #expect(sized.modeString == "-rwsr-xr-x")
            #expect(sized.uid == 1234)
            #expect(sized.gid == 5678)
            #expect(sized.owner == nil)
            #expect(sized.modified == Date(timeIntervalSince1970: 1_700_000_000))

            // The listed names address the same files again.
            let sub = try await backend.listDirectory(id, path: "/work/sub", limit: 10)
            #expect(sub.entries.map(\.name) == ["deep.txt"])
            let viaLink = try await backend.listDirectory(id, path: "/work/dirlink", limit: 1000)
            #expect(viaLink.entries.contains { $0.name == "passwd" })
            #expect(try await backend.readFile(id, path: "/work/new\nline", maxBytes: 10) == Data("n".utf8))
            #expect(try await backend.readFile(id, path: "/work/-dash", maxBytes: 10) == Data("x".utf8))
            #expect(try await backend.readFile(id, path: "/work/cr\r", maxBytes: 10) == Data("c".utf8))
            #expect(try await backend.readFile(id, path: "/work/trailing space ", maxBytes: 10) == Data("s".utf8))
        }
    }

    @Test(arguments: images)
    func truncatesAtTheLimitAndReportsUnreadableDirectories(image: String) async throws {
        try await Integration.withContainer(backend, image: image) { id in
            try await Integration.shell(
                backend, id, "mkdir /many /empty && cd /many && for i in $(seq 1 30); do : > f$i; done && : > .dot")
            let cut = try await backend.listDirectory(id, path: "/many", limit: 10)
            #expect(cut.entries.count == 10)
            #expect(cut.isTruncated)
            let exact = try await backend.listDirectory(id, path: "/many", limit: 31)
            #expect(exact.entries.count == 31)
            #expect(!exact.isTruncated)
            let oneShort = try await backend.listDirectory(id, path: "/many", limit: 30)
            #expect(oneShort.entries.count == 30)
            #expect(oneShort.isTruncated)
            let empty = try await backend.listDirectory(id, path: "/empty", limit: 10)
            #expect(empty.entries.isEmpty)
            #expect(empty.method == .stat)
            #expect(!empty.isTruncated)

            let missing = await Integration.backendError {
                _ = try await backend.listDirectory(id, path: "/cd-it-nope", limit: 10)
            }
            guard case .commandFailed(let command, let exitCode, let message) = missing else {
                Issue.record("expected commandFailed, got \(String(describing: missing))")
                return
            }
            #expect(exitCode == FileListing.missingExitCode)
            #expect(command.contains(" exec -- \(id) sh -c "))
            #expect(message == "“/cd-it-nope” does not exist.")

            let notADirectory = await Integration.backendError {
                _ = try await backend.listDirectory(id, path: "/etc/passwd", limit: 10)
            }
            guard case .commandFailed(_, FileListing.notADirectoryExitCode, let reason) = notADirectory else {
                Issue.record("expected commandFailed 68, got \(String(describing: notADirectory))")
                return
            }
            #expect(reason == "“/etc/passwd” is not a directory.")

            let relative = await Integration.backendError {
                _ = try await backend.listDirectory(id, path: "etc", limit: 1)
            }
            guard case .other = relative else {
                Issue.record("expected a refusal for a relative path, got \(String(describing: relative))")
                return
            }
        }
    }

    /// Without `stat` the script falls back to `ls -lAn --full-time`, which both BusyBox and GNU `ls` have.
    @Test(arguments: images)
    func fallsBackToLsWithoutStat(image: String) async throws {
        try await Integration.withContainer(backend, image: image) { id in
            try await Integration.shell(
                backend, id,
                """
                set -e
                mkdir -p /work/sub && cd /work
                printf 1234567 > 'a b.txt' && chmod 640 'a b.txt' && touch -d @1700000000 'a b.txt'
                ln -s /etc/passwd link
                printf h > .hidden
                rm -f "$(command -v stat)"
                """)
            let listing = try await backend.listDirectory(id, path: "/work", limit: 100)
            #expect(listing.method == .lsFullTime)
            #expect(Set(listing.entries.map(\.name)) == ["a b.txt", "link", ".hidden", "sub"])
            let byName = Dictionary(listing.entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let file = try #require(byName["a b.txt"])
            #expect(file.kind == .file)
            #expect(file.size == 7)
            #expect(file.permissions == 0o640)
            #expect(file.uid == 0)
            #expect(file.modified == Date(timeIntervalSince1970: 1_700_000_000))
            #expect(byName["link"]?.kind == .symlink)
            #expect(byName["link"]?.linkTarget == "/etc/passwd")
            #expect(byName["sub"]?.kind == .directory)

            let root = try await backend.listDirectory(id, path: "/", limit: 1000)
            #expect(root.method == .lsFullTime)
            #expect(root.entries.contains { $0.name == "etc" && $0.kind == .directory })
            let dev = try await backend.listDirectory(id, path: "/dev", limit: 1000)
            #expect(dev.entries.contains { $0.name == "null" && $0.kind == .characterDevice })
        }
    }

    /// A real container whose `sh` has been removed: the listing is "unavailable", not an error. Also records
    /// what the runtime says for an executable that does not exist, which is what the detection keys on.
    @Test func imageWithoutShellIsReportedAsUnavailable() async throws {
        try await Integration.withContainer(backend) { id in
            let ghost = try await backend.execCapture(id, command: ["cd-it-no-such-binary"], workingDirectory: nil)
            #expect(ghost.exitCode == 1)  // not 126/127: the runtime fails before anything runs
            #expect(ghost.stderr.contains("failed to find target executable cd-it-no-such-binary"))
            #expect(FileListing.indicatesMissingShell(exitCode: ghost.exitCode, stderr: ghost.stderr))

            let removed = try await backend.execCapture(id, command: ["rm", "/bin/sh"], workingDirectory: nil)
            try #require(removed.exitCode == 0, "\(removed.stderr)")
            let listing = try await backend.listDirectory(id, path: "/", limit: 100)
            #expect(listing.unavailable == .noShell)
            #expect(listing.entries.isEmpty)
            #expect(listing.method == nil)

            // The direct-exec calls do not need a shell.
            #expect(try await backend.readFile(id, path: "/etc/hostname", maxBytes: 100).isEmpty == false)
            try await backend.makeDirectory(id, path: "/made-without-sh")
            try await backend.deleteItem(id, path: "/made-without-sh")

            // A tool that is missing is a command failure that names the tool, not "no shell".
            _ = try await backend.execCapture(id, command: ["rm", "/usr/bin/head"], workingDirectory: nil)
            let noHead = await Integration.backendError {
                _ = try await backend.readFile(id, path: "/etc/hostname", maxBytes: 10)
            }
            guard case .commandFailed(_, 1, let message) = noHead else {
                Issue.record("expected commandFailed, got \(String(describing: noHead))")
                return
            }
            #expect(message.contains("failed to find target executable head"))
        }
    }

    /// A shell but neither `stat` nor `ls`.
    @Test func imageWithoutListingToolsIsReportedAsUnavailable() async throws {
        try await Integration.withContainer(backend) { id in
            try await Integration.shell(backend, id, "rm -f /bin/stat /bin/ls /usr/bin/stat /usr/bin/ls")
            let listing = try await backend.listDirectory(id, path: "/etc", limit: 100)
            #expect(listing.unavailable == .noListingTool)
            #expect(listing.entries.isEmpty)
        }
    }

    // MARK: Reading

    @Test(arguments: images)
    func readsTextBinaryAndCapsTheSize(image: String) async throws {
        try await Integration.withContainer(backend, image: image) { id in
            try await Integration.shell(
                backend, id,
                #"""
                set -e
                mkdir /r && cd /r
                printf 'line one\nline two\n' > 'text file.txt'
                i=0; while [ $i -lt 256 ]; do printf "\\$(printf '%03o' $i)"; i=$((i+1)); done > binary.bin
                head -c 1048576 /dev/zero > big.bin
                : > empty
                """#)
            #expect(
                try await backend.readFile(id, path: "/r/text file.txt", maxBytes: 4096)
                    == Data("line one\nline two\n".utf8))
            #expect(try await backend.readFile(id, path: "/r/text file.txt", maxBytes: 4) == Data("line".utf8))
            #expect(try await backend.readFile(id, path: "/r/binary.bin", maxBytes: 4096) == Data(0...255))
            let capped = try await backend.readFile(id, path: "/r/big.bin", maxBytes: 1000)
            #expect(capped.count == 1000)
            #expect(try await backend.readFile(id, path: "/r/big.bin", maxBytes: 2 << 20).count == 1 << 20)
            #expect(try await backend.readFile(id, path: "/r/empty", maxBytes: 10).isEmpty)
            #expect(try await backend.readFile(id, path: "/r/text file.txt", maxBytes: 0).isEmpty)

            let missing = await Integration.backendError {
                _ = try await backend.readFile(id, path: "/r/nope", maxBytes: 10)
            }
            guard case .commandFailed(let command, 1, let message) = missing else {
                Issue.record("expected commandFailed, got \(String(describing: missing))")
                return
            }
            #expect(command.hasSuffix(" exec -- \(id) head -c 10 -- /r/nope"))
            #expect(message.localizedCaseInsensitiveContains("no such file or directory"))

            let directory = await Integration.backendError {
                _ = try await backend.readFile(id, path: "/r", maxBytes: 10)
            }
            guard case .commandFailed = directory else {
                Issue.record("expected commandFailed for a directory, got \(String(describing: directory))")
                return
            }
        }
    }

    // MARK: Changing

    @Test(arguments: images)
    func makesMovesAndDeletes(image: String) async throws {
        try await Integration.withContainer(backend, image: image) { id in
            func names(_ path: String) async throws -> Set<String> {
                Set(try await backend.listDirectory(id, path: path, limit: 1000).entries.map(\.name))
            }
            try await backend.makeDirectory(id, path: "/w")
            try await backend.makeDirectory(id, path: "/w/new folder")
            try await backend.makeDirectory(id, path: "/w/-p")
            try await backend.makeDirectory(id, path: "/w/ünï")
            #expect(try await names("/w") == ["new folder", "-p", "ünï"])

            let exists = await Integration.backendError { try await backend.makeDirectory(id, path: "/w/new folder") }
            guard case .commandFailed(let command, 1, let message) = exists else {
                Issue.record("expected commandFailed, got \(String(describing: exists))")
                return
            }
            #expect(command.hasSuffix(" exec -- \(id) mkdir -- '/w/new folder'"))
            #expect(message.localizedCaseInsensitiveContains("exists"))
            let noParent = await Integration.backendError { try await backend.makeDirectory(id, path: "/w/a/b/c") }
            guard case .commandFailed = noParent else {
                Issue.record("expected commandFailed, got \(String(describing: noParent))")
                return
            }

            try await Integration.shell(backend, id, "printf data > '/w/new folder/f.txt'")
            try await backend.moveItem(id, from: "/w/new folder/f.txt", to: "/w/new folder/renamed file.txt")
            #expect(try await names("/w/new folder") == ["renamed file.txt"])
            try await backend.moveItem(id, from: "/w/new folder/renamed file.txt", to: "/w/-p/-moved")
            #expect(try await names("/w/-p") == ["-moved"])
            #expect(try await backend.readFile(id, path: "/w/-p/-moved", maxBytes: 10) == Data("data".utf8))
            try await backend.moveItem(id, from: "/w/-p", to: "/w/renamed dir")
            #expect(try await names("/w") == ["new folder", "renamed dir", "ünï"])

            let moveMissing = await Integration.backendError {
                try await backend.moveItem(id, from: "/w/ghost", to: "/w/x")
            }
            guard case .commandFailed = moveMissing else {
                Issue.record("expected commandFailed, got \(String(describing: moveMissing))")
                return
            }
            let moveRoot = await Integration.backendError { try await backend.moveItem(id, from: "/", to: "/w/x") }
            #expect(moveRoot == .other("The root directory cannot be renamed."))

            try await backend.deleteItem(id, path: "/w/renamed dir/-moved")
            #expect(try await names("/w/renamed dir").isEmpty)
            try await Integration.shell(backend, id, "mkdir -p /w/full/a/b && printf x > /w/full/a/b/c")
            try await backend.deleteItem(id, path: "/w/full")
            #expect(try await names("/w") == ["new folder", "renamed dir", "ünï"])

            // Guards: nothing is run for `/`, system directories or relative paths.
            for path in ["/", "/etc", "/usr/bin", "/var/lib", "//etc/", "/w/../etc"] {
                let refused = await Integration.backendError { try await backend.deleteItem(id, path: path) }
                guard case .other = refused else {
                    Issue.record("deleting \(path) should be refused, got \(String(describing: refused))")
                    continue
                }
            }
            let relative = await Integration.backendError { try await backend.deleteItem(id, path: "w") }
            guard case .other = relative else {
                Issue.record("expected a refusal, got \(String(describing: relative))")
                return
            }
            #expect(try await names("/etc").contains("passwd"))
            #expect(try await names("/usr/bin").isEmpty == false)
        }
    }
}
