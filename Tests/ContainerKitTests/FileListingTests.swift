import Foundation
import Testing

@testable import ContainerKit

/// The Files tab listing: parser against captured-style GNU and BusyBox output, and the script itself run
/// by real POSIX shells.
@Suite("File listing")
struct FileListingTests {
    static let nonce = "a1b2c3d4e5f60718"
    let now = Date(timeIntervalSince1970: 1_762_948_800)  // 2025-11-12 12:00:00 UTC

    func parse(_ text: String, limit: Int = 2000) -> ContainerDirectoryListing? {
        FileListing.parse(Data(text.utf8), nonce: Self.nonce, path: "/x", limit: limit, now: now)
    }

    // MARK: stat method

    /// `stat -c` output as GNU coreutils 9 (Debian) prints it; BusyBox 1.37 prints the same fields.
    static let statOutput = """
        \(nonce) S
        \(nonce) M stat
        \(nonce) E 41ed/4096/0/0/1762900000/root/root/etc
        \(nonce) E 81a4/1234/0/0/1762900100/root/root/hosts
        \(nonce) E a1ff/7/0/0/1700000000/root/root/bin
        \(nonce) E 81ed/919760/1000/1000/1700000000/UNKNOWN/UNKNOWN/run me.sh
        \(nonce) E 8180/12/70/70/1762900200/postgres/postgres/.pgpass
        \(nonce) E 2190/0/0/5/1762900300/root/tty/console
        \(nonce) E 43ff/4096/0/0/1762900400/root/root/tmp
        \(nonce) E a1ff/11/0/0/1700000000/root/root/latest
        \(nonce) K bin
        \(nonce) T usr/bin
        \(nonce) L latest
        \(nonce) T /nonexistent
        \(nonce) Z

        """

    @Test func parsesStatRecords() throws {
        let listing = try #require(parse(Self.statOutput))
        #expect(listing.method == .stat)
        #expect(!listing.isTruncated)
        #expect(listing.unavailable == nil)
        #expect(
            listing.entries.map(\.name) == ["etc", "hosts", "bin", "run me.sh", ".pgpass", "console", "tmp", "latest"])
        let byName = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.name, $0) })

        let etc = try #require(byName["etc"])
        #expect(etc.kind == .directory)
        #expect(etc.modeString == "drwxr-xr-x")
        #expect(etc.ownerDescription == "root:root")
        #expect(etc.modified == Date(timeIntervalSince1970: 1_762_900_000))
        #expect(etc.isBrowsable)

        let hosts = try #require(byName["hosts"])
        #expect(hosts.kind == .file)
        #expect(hosts.size == 1234)
        #expect(hosts.octalMode == "644")

        let bin = try #require(byName["bin"])
        #expect(bin.kind == .symlink)
        #expect(bin.linkTarget == "usr/bin")
        #expect(bin.linkPointsToDirectory)
        #expect(bin.isBrowsable)

        let dangling = try #require(byName["latest"])
        #expect(dangling.linkTarget == "/nonexistent")
        #expect(!dangling.linkPointsToDirectory)

        let script = try #require(byName["run me.sh"])
        #expect(script.owner == nil)  // UNKNOWN → numeric ids only
        #expect(script.ownerDescription == "1000:1000")
        #expect(script.modeString == "-rwxr-xr-x")

        #expect(byName[".pgpass"]?.isHidden == true)
        #expect(byName[".pgpass"]?.modeString == "-rw-------")
        #expect(byName["console"]?.kind == .characterDevice)
        #expect(byName["tmp"]?.modeString == "drwxrwxrwt")
    }

    @Test func namesWithNewlinesSpacesAndUnicodeSurvive() throws {
        let n = Self.nonce
        // "two\nlines", a name that imitates a record with a *wrong* nonce, CR at the end, and unicode.
        let output =
            "\(n) S\n\(n) M stat\n"
            + "\(n) E 81a4/1/0/0/1/root/root/two\nlines\n"
            + "\(n) E 81a4/2/0/0/1/root/root/evil\n0000000000000000 E 41ed/0/0/0/1/root/root/forged\n"
            + "\(n) E 81a4/3/0/0/1/root/root/cr\r\n"
            + "\(n) E 81a4/4/0/0/1/root/root/  café — 日本語 🚀 'q' \"d\" $x `y` \\z\n"
            + "\(n) E a1ff/5/0/0/1/root/root/link\nname\n"
            + "\(n) L link\nname\n\(n) T target\nwith newline\n"
            + "\(n) Z\n"
        let listing = try #require(parse(output))
        #expect(
            listing.entries.map(\.name) == [
                "two\nlines", "evil\n0000000000000000 E 41ed/0/0/0/1/root/root/forged", "cr\r",
                "  café — 日本語 🚀 'q' \"d\" $x `y` \\z", "link\nname",
            ])
        #expect(listing.entries.map(\.size) == [1, 2, 3, 4, 5])
        #expect(listing.entries.last?.linkTarget == "target\nwith newline")
    }

    @Test func truncationAndLimit() throws {
        let n = Self.nonce
        let marked = "\(n) S\n\(n) M stat\n\(n) M truncated\n\(n) E 81a4/1/0/0/1/a/a/one\n\(n) Z\n"
        #expect(parse(marked)?.isTruncated == true)
        #expect(parse(marked)?.method == .stat)
        let many = "\(n) S\n\(n) M stat\n" + (0..<5).map { "\(n) E 81a4/1/0/0/1/a/a/f\($0)\n" }.joined()
        let limited = try #require(parse(many, limit: 3))
        #expect(limited.entries.count == 3)
        #expect(limited.isTruncated)
    }

    @Test func emptyDirectoryAndGarbage() throws {
        let n = Self.nonce
        #expect(parse("\(n) S\n\(n) M stat\n\(n) Z\n")?.entries.isEmpty == true)
        #expect(parse("") == nil)
        #expect(parse("sh: not found\n") == nil)
        // A malformed record is skipped, not fatal.
        #expect(parse("\(n) S\n\(n) M stat\n\(n) E zz/1\n\(n) E 81a4/1/0/0/1/a/a/ok\n")?.entries.map(\.name) == ["ok"])
    }

    // MARK: ls fallbacks

    @Test func parsesBusyBoxFullTime() throws {
        let n = Self.nonce
        let output = """
            \(n) S
            \(n) M ls-full
            total 16
            drwxr-xr-x    2 0        0             4096 2025-11-10 08:15:00 +0000 bin
            -rw-r--r--    1 0        0               27 2025-11-11 23:59:58 +0100 my notes.txt
            lrwxrwxrwx    1 0        0                7 2024-01-15 10:30:00 +0000 lib64 -> usr/lib
            crw-rw-rw-    1 0        0           1,   3 2025-11-12 09:00:00 +0000 null
            -rwsr-xr-x    1 0        0            14120 2024-01-15 10:30:00 +0000 su
            \(n) Z

            """
        let listing = try #require(parse(output))
        #expect(listing.method == .lsFullTime)
        #expect(listing.entries.map(\.name) == ["bin", "my notes.txt", "lib64", "null", "su"])
        #expect(listing.entries[0].kind == .directory)
        #expect(listing.entries[0].uid == 0)
        #expect(listing.entries[0].owner == nil)
        #expect(listing.entries[1].size == 27)
        // 23:59:58 +0100 is 22:59:58 UTC.
        #expect(listing.entries[1].modified == Date(timeIntervalSince1970: 1_762_901_998))
        #expect(listing.entries[2].kind == .symlink)
        #expect(listing.entries[2].linkTarget == "usr/lib")
        #expect(listing.entries[3].kind == .characterDevice)
        #expect(listing.entries[3].size == 0)
        #expect(listing.entries[4].modeString == "-rwsr-xr-x")
        #expect(listing.entries[4].octalMode == "4755")
    }

    @Test func parsesGNUFullTimeAndFallsThroughFailedAttempts() throws {
        let n = Self.nonce
        // BusyBox without long options: the first attempt prints nothing useful, the second succeeds.
        let output = """
            \(n) S
            \(n) M ls-full
            \(n) M ls-long
            total 8
            -rw-r--r-- 1 root root 1234 Nov 11 10:30 recent.log
            -rw-r--r-- 1 root root   99 Dec 24 10:30 last-year.log
            drwx------ 2 70 70 4096 Jan 15  2023 data
            -rw-r--r--. 1 0 0 5 2025-11-12 10:30:00.123456789 +0000 selinux
            \(n) Z

            """
        let listing = try #require(parse(output))
        #expect(listing.method == .lsLong)
        #expect(listing.entries.map(\.name) == ["recent.log", "last-year.log", "data", "selinux"])
        #expect(listing.entries[0].owner == "root")
        #expect(listing.entries[0].uid == nil)
        #expect(listing.entries[0].modified == Date(timeIntervalSince1970: 1_762_857_000))  // 2025-11-11 10:30 UTC
        // Dec 24 would be in the future relative to `now`, so it is last year's.
        #expect(listing.entries[1].modified == Date(timeIntervalSince1970: 1_735_036_200))  // 2024-12-24 10:30 UTC
        #expect(listing.entries[2].modified == Date(timeIntervalSince1970: 1_673_740_800))  // 2023-01-15
        #expect(listing.entries[2].modeString == "drwx------")
        #expect(listing.entries[3].size == 5)
    }

    @Test func lsSkipsDotEntriesAndNoise() {
        #expect(FileListing.parseLsLine("total 12") == nil)
        #expect(FileListing.parseLsLine("drwxr-xr-x 2 0 0 4096 Jan 15 10:30 .") == nil)
        #expect(FileListing.parseLsLine("drwxr-xr-x 2 0 0 4096 Jan 15 10:30 ..") == nil)
        #expect(FileListing.parseLsLine("ls: cannot access 'x': No such file or directory") == nil)
        #expect(FileListing.parseLsLine("-rw-r--r-- 1 0 0 3 Jan 15 10:30  leading space")?.name == " leading space")
        #expect(FileListing.parseLsLine("-rw-r--r-- 1 0 0 3 Jan 15 10:30 a -> b")?.name == "a -> b")  // not a link
    }

    @Test func modeStrings() {
        #expect(FileListing.parseModeString("drwxrwxrwt")?.1 == 0o1777)
        #expect(FileListing.parseModeString("-rwSr-Sr-T")?.1 == 0o7644)
        #expect(FileListing.parseModeString("-rwxr-sr-x+")?.1 == 0o2755)
        #expect(FileListing.parseModeString("total") == nil)
        #expect(FileListing.parseModeString("-rw-r--r-") == nil)
        #expect(ContainerFileEntry(name: "x", kind: .file, permissions: 0o7644).modeString == "-rwSr-Sr-T")
        #expect(ContainerFileEntry(name: "x", kind: .socket, permissions: 0o6755).modeString == "srwsr-sr-x")
    }

    // MARK: interpret

    @Test func interpretsUnavailableAndFailures() {
        func interpret(_ code: Int32, _ stdout: String, _ stderr: String) -> FileListing.Outcome {
            FileListing.interpret(
                exitCode: code, stdout: Data(stdout.utf8), stderr: stderr, nonce: Self.nonce, path: "/x", limit: 10)
        }
        let n = Self.nonce
        #expect(
            interpret(0, "\(n) S\n\(n) M ls-full\n\(n) M ls-long\n\(n) M ls-basic\n\(n) M none\n\(n) Z\n", "")
                == .listing(ContainerDirectoryListing(path: "/x", method: nil, unavailable: .noListingTool)))
        let noShell = FileListing.Outcome.listing(
            ContainerDirectoryListing(path: "/x", method: nil, unavailable: .noShell))
        #expect(interpret(127, "", "") == noShell)
        #expect(interpret(1, "", "Error: failed to find target executable sh") == noShell)
        #expect(interpret(1, "", "exec: \"sh\": executable file not found in $PATH") == noShell)
        #expect(
            interpret(66, "", "sh: cd: can't cd to /x: No such file or directory")
                == .failure(message: "sh: cd: can't cd to /x: No such file or directory"))
        #expect(interpret(66, "", "") == .failure(message: "“/x” cannot be opened."))
        #expect(interpret(67, "", "") == .failure(message: "“/x” does not exist."))
        #expect(interpret(68, "", "") == .failure(message: "“/x” is not a directory."))
        #expect(
            interpret(1, "", "Error: container web is not running") == .failure(message: "container web is not running")
        )
        #expect(interpret(1, "", "") == .failure(message: "Listing “/x” failed with exit code 1."))
    }

    @Test func commandShape() {
        let command = FileListing.command(nonce: "ab", path: "/my dir", limit: 5)
        #expect(command == ["sh", "-c", FileListing.script, "sh", "ab", "/my dir", "5"])
        // Nothing user-controlled is ever part of the script text.
        #expect(!FileListing.script.contains("/my dir"))
        let nonce = FileListing.makeNonce()
        #expect(nonce.count == 16)
        #expect(nonce.allSatisfy { $0.isHexDigit })
        #expect(nonce != FileListing.makeNonce())
    }
}
