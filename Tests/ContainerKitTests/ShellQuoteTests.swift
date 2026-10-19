import Foundation
import Testing
import ContainerKit

@Suite("ShellQuote")
struct ShellQuoteTests {
    static let tricky = ["a;b", "x|y", "", "*", "it's", "$HOME", "!x", "C:\\path", "a b", "`id`", "~", "#c", "(x)", "line\nbreak"]

    @Test func safeWordsStayBare() {
        #expect(ShellQuote.quote("ghcr.io/x/y:1.2@sha256") == "ghcr.io/x/y:1.2@sha256")
        #expect(ShellQuote.quote("KEY=v,a+b%c") == "KEY=v,a+b%c")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
        #expect(ShellQuote.quote("*") == "'*'")
        #expect(ShellQuote.quote("é") == "'é'")
    }

    @Test func commandLineDisplayUsesShellQuote() {
        let line = CommandLine(executable: "/usr/local/bin/container", arguments: ["run", "", "a;b"])
        #expect(line.display == "/usr/local/bin/container run '' 'a;b'")
    }

    /// Every word survives a real `/bin/sh` parse unchanged.
    @Test func roundTripsThroughSh() async throws {
        let script = "printf '%s\\n' " + ShellQuote.join(Self.tricky)
        let result = try await ProcessRunner().run(["/bin/sh", "-c", script], timeout: .seconds(10))
        #expect(result.exitCode == 0)
        let expected = Self.tricky.map { $0 + "\n" }.joined()
        #expect(result.stdoutText == expected)
    }
}
