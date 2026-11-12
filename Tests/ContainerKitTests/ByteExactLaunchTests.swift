import Foundation
import Testing

@testable import ContainerKit

/// `Process` decomposes Unicode in arguments and environment values; `ByteExactLaunch` must deliver the bytes
/// the caller wrote. The process tests run real `/usr/bin/printf` and `/bin/sh`, never the container CLI.
@Suite("Byte-exact launch")
struct ByteExactLaunchTests {
    static let samples = [
        "caf\u{00E9}", "한국어 이름", "na\u{00EF}ve \u{00FC}ber", "trailing newline \u{00E9}\n\n",
        "100% \u{00E9} $HOME `x` 'q' \"d\" \\n",
        "\u{00E9}", "-e=\u{00C5}ngstr\u{00F6}m",
    ]

    @Test func asciiAndAlreadyDecomposedTextIsLeftAlone() {
        #expect(ByteExactLaunch.rewrite(arguments: ["/bin/echo", "plain", "a b"], environment: ["K": "v"]) == nil)
        #expect(!ByteExactLaunch.isAltered("cafe\u{0301}"))  // already decomposed: Process keeps it
        #expect(!ByteExactLaunch.isAltered("日本語"))  // no decomposition exists
        #expect(ByteExactLaunch.isAltered("caf\u{00E9}"))
    }

    @Test func scriptIsAsciiAndKeepsPlainArgumentsPositional() throws {
        let launch = try #require(
            ByteExactLaunch.rewrite(
                arguments: ["/usr/local/bin/container", "run", "-e", "K=\u{00E9}"], environment: [:]))
        #expect(launch.arguments.prefix(2) == ["/bin/sh", "-c"])
        #expect(launch.arguments.dropFirst(3) == ["sh", "/usr/local/bin/container", "run", "-e"])
        let script = launch.arguments[2]
        #expect(script.utf8.allSatisfy { $0 < 0x80 })
        #expect(script == #"a3=$(printf '\113\75\303\251x'); a3=${a3%x}; exec "${1}" "${2}" "${3}" "$a3""#)
    }

    @Test(arguments: samples) func argumentsArriveByteExact(_ sample: String) async throws {
        let result = try await ProcessRunner().run(
            ["/usr/bin/printf", "%s|%s", sample, "plain"], timeout: .seconds(10))
        #expect(result.exitCode == 0)
        #expect(result.stdout == Data((sample + "|plain").utf8))
    }

    @Test func manyArgumentsKeepTheirOrder() async throws {
        let arguments = (1...12).map { $0.isMultiple(of: 3) ? "\u{00E9}\($0)" : "p\($0)" }
        let result = try await ProcessRunner().run(
            ["/usr/bin/printf", "%s,"] + arguments, timeout: .seconds(10))
        #expect(result.stdout == Data(arguments.map { $0 + "," }.joined().utf8))
    }

    @Test func environmentValuesArriveByteExact() async throws {
        let result = try await ProcessRunner().run(
            ["/bin/sh", "-c", #"printf '%s|%s' "$CD_ACCENT" "$CD_PLAIN""#], stdin: nil, timeout: .seconds(10),
            environment: ["CD_ACCENT": "caf\u{00E9} 한", "CD_PLAIN": "x"])
        #expect(result.stdout == Data("caf\u{00E9} 한|x".utf8))
    }

    @Test func exitStatusAndStdinPassThroughTheTrampoline() async throws {
        let result = try await ProcessRunner().run(
            ["/bin/sh", "-c", "cat; exit 7", "\u{00E9}"], stdin: Data("in".utf8), timeout: .seconds(10))
        #expect(result.exitCode == 7)
        #expect(result.stdout == Data("in".utf8))
    }
}
