import Darwin
import Foundation
import Testing

@testable import ContainerKit

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    let runner = ProcessRunner(killGracePeriod: .milliseconds(500), drainGracePeriod: .milliseconds(500))

    func sh(_ script: String) -> [String] { ["/bin/sh", "-c", script] }

    @Test func capturesStdoutStderrAndExitCode() async throws {
        let result = try await runner.run(sh("echo out; echo err >&2; exit 3"))
        #expect(result.exitCode == 3)
        #expect(result.stdoutText == "out\n")
        #expect(result.stderrText == "err\n")
    }

    @Test func largeOutputOnBothPipesDoesNotDeadlock() async throws {
        // 1 MB on each pipe, far beyond the 64 KB pipe buffer.
        let script = "head -c 1048576 /dev/zero | tr '\\0' a; head -c 1048576 /dev/zero | tr '\\0' b >&2"
        let result = try await runner.run(sh(script), timeout: .seconds(30))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == 1_048_576)
        #expect(result.stderr.count == 1_048_576)
    }

    @Test func writesStdin() async throws {
        let result = try await runner.run(sh("read line; echo got:$line"), stdin: Data("secret\n".utf8))
        #expect(result.stdoutText == "got:secret\n")
    }

    @Test func environmentHasPathAndNoTerm() async throws {
        let result = try await runner.run(
            sh("echo \"$PATH\"; echo \"term=$(/usr/bin/printenv TERM || echo unset)\"; echo \"$EXTRA\""),
            stdin: nil, timeout: nil, environment: ["EXTRA": "yes"])
        let lines = result.stdoutText.split(separator: "\n").map(String.init)
        #expect(lines[0].hasPrefix("/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"))
        #expect(lines[1] == "term=unset")
        #expect(lines[2] == "yes")
    }

    @Test func childEnvironmentStripsColorVariables() {
        let env = ProcessRunner.childEnvironment(base: [
            "TERM": "xterm", "CLICOLOR_FORCE": "1", "PATH": "/x:/usr/bin", "HOME": "/h",
        ])
        #expect(env["TERM"] == nil)
        #expect(env["CLICOLOR_FORCE"] == nil)
        #expect(env["NO_COLOR"] == "1")
        #expect(env["HOME"] == "/h")
        #expect(env["PATH"] == "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/x")
    }

    @Test func timeoutThrowsCommandFailed() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect {
            _ = try await runner.run(sh("exec sleep 30"), timeout: .milliseconds(300))
        } throws: { error in
            guard case BackendError.commandFailed(_, _, let message) = error else { return false }
            return message.contains("Timed out")
        }
        #expect(clock.now - start < .seconds(5))
    }

    @Test func cancellationTerminatesProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("cd-pid-\(UUID().uuidString)")
        let task = Task { try await runner.run(sh("echo $$ > '\(pidFile.path)'; exec sleep 30")) }
        let pid = try await waitForPID(in: pidFile)
        task.cancel()
        await #expect(throws: BackendError.cancelled) { _ = try await task.value }
        #expect(await waitUntilDead(pid))
        try? FileManager.default.removeItem(at: pidFile)
    }

    @Test func missingExecutableFailsCleanly() async {
        await #expect {
            _ = try await runner.run(["/nonexistent/binary"])
        } throws: { error in
            if case BackendError.commandFailed(_, -1, _) = error { return true }
            return false
        }
    }

    // MARK: Streaming

    @Test func streamYieldsLinesInOrderAsTheyArrive() async throws {
        var received: [OutputLine] = []
        let clock = ContinuousClock()
        var firstLineAt: ContinuousClock.Instant?
        let start = clock.now
        for try await line in runner.stream(sh("echo one; echo two; sleep 1; echo three >&2; echo four")) {
            if firstLineAt == nil { firstLineAt = clock.now }
            received.append(line)
        }
        #expect(received.filter { $0.stream == .stdout }.map(\.text) == ["one", "two", "four"])
        #expect(received.filter { $0.stream == .stderr }.map(\.text) == ["three"])
        // The first line arrived before the one-second sleep finished.
        #expect(try #require(firstLineAt) - start < .milliseconds(900))
    }

    @Test func streamTreatsCarriageReturnAsLineBreak() async throws {
        let (lines, error) = await drain(runner.stream(sh("printf '[1/3] a\\r[2/3] b\\r[3/3] c\\r\\ndone\\n'")))
        #expect(error == nil)
        #expect(lines.map(\.text) == ["[1/3] a", "[2/3] b", "[3/3] c", "done"])
    }

    @Test func streamNonZeroExitThrowsWithCleanedStderr() async throws {
        let (lines, error) = await drain(runner.stream(sh("echo '[1/6] Fetching' >&2; echo 'Error: boom' >&2; exit 4")))
        #expect(lines.map(\.text) == ["[1/6] Fetching", "Error: boom"])
        guard case BackendError.commandFailed(_, let code, let message) = try #require(error) else {
            Issue.record("unexpected error \(String(describing: error))"); return
        }
        #expect(code == 4)
        #expect(message == "boom")
    }

    @Test func cancellingConsumerKillsStreamedProcess() async throws {
        var pid: pid_t = 0
        for try await line in runner.stream(sh("echo $$; exec sleep 30")) {
            pid = pid_t(line.text) ?? 0
            break  // ends iteration -> onTermination -> SIGTERM
        }
        #expect(pid > 0)
        #expect(await waitUntilDead(pid))
    }

    @Test func cancellingConsumerTaskKillsStreamedProcess() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("cd-pid-\(UUID().uuidString)")
        let stream = runner.stream(sh("echo $$ > '\(pidFile.path)'; echo started; exec sleep 30"))
        let task = Task { await drain(stream) }
        let pid = try await waitForPID(in: pidFile)
        task.cancel()
        _ = await task.value
        #expect(await waitUntilDead(pid))
        try? FileManager.default.removeItem(at: pidFile)
    }

    // MARK: Line splitting

    @Test func lineSplitterHandlesPartialChunksAndANSI() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("hel".utf8)).isEmpty)
        #expect(splitter.feed(Data("lo\r\nwor".utf8)) == ["hello"])
        #expect(splitter.feed(Data("ld\n\n".utf8)) == ["world", ""])
        #expect(splitter.feed(Data("\u{1B}[1;32mgreen\u{1B}[0m\n".utf8)) == ["green"])
        #expect(splitter.feed(Data("tail".utf8)).isEmpty)
        #expect(splitter.flush() == ["tail"])
    }

    // MARK: Helpers

    private func waitForPID(in file: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: file, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BackendError.other("child never wrote its pid")
    }

    private func waitUntilDead(_ pid: pid_t) async -> Bool {
        for _ in 0..<60 {
            if kill(pid, 0) != 0 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

@Suite("ProcessRunner robustness")
struct ProcessRunnerRobustnessTests {
    let runner = ProcessRunner(killGracePeriod: .milliseconds(500), drainGracePeriod: .milliseconds(500))

    /// Writing stdin to a child that exits without reading must not SIGPIPE the test process.
    @Test func stdinToEarlyExitingChildDoesNotKillUs() async throws {
        for _ in 0..<5 {
            let result = try await runner.run(["/usr/bin/true"], stdin: Data(count: 1 << 20), timeout: .seconds(10))
            #expect(result.exitCode == 0)
        }
    }

    /// A grandchild that keeps the pipes open must not stall `run` past the drain grace.
    @Test func backgroundGrandchildDoesNotStallRun() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await runner.run(["/bin/sh", "-c", "sleep 30 & echo started"], timeout: .seconds(20))
        #expect(result.stdoutText == "started\n")
        #expect(clock.now - start < .seconds(5))
    }

    @Test func timeoutMessageUsesMilliseconds() {
        #expect(ProcessRunner.describe(.milliseconds(300)) == "300 ms")
        #expect(ProcessRunner.describe(.seconds(2)) == "2 s")
        #expect(ProcessRunner.describe(.milliseconds(1500)) == "1.5 s")
    }

    @Test func childEnvironmentStripsContainerOverrides() {
        let env = ProcessRunner.childEnvironment(base: [
            "CONTAINER_DEFAULT_PLATFORM": "linux/amd64", "CONTAINER_DEBUG": "1", "HOME": "/h",
        ])
        #expect(env["CONTAINER_DEFAULT_PLATFORM"] == nil)
        #expect(env["CONTAINER_DEBUG"] == nil)
        #expect(env["HOME"] == "/h")
    }

    @Test func lineSplitterCapsLineLength() {
        var splitter = LineSplitter()
        let long = Data(repeating: UInt8(ascii: "x"), count: LineSplitter.maxLineLength * 2 + 10)
        let lines = splitter.feed(long + Data("\n".utf8))
        #expect(lines.map(\.count) == [LineSplitter.maxLineLength, LineSplitter.maxLineLength, 10])
    }

    @Test func lineSplitterSplitsOnCharacterBoundary() {
        var splitter = LineSplitter()
        let text = String(repeating: "x", count: LineSplitter.maxLineLength - 1) + "é\n"
        let lines = splitter.feed(Data(text.utf8))
        #expect(lines.count == 2)
        #expect(lines.last == "é")
        #expect(!lines.joined().contains("\u{FFFD}"))
    }

    @Test func lineSplitterKeepsBlankCRLFLines() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("a\r\n\r\nb\r\n".utf8)) == ["a", "", "b"])
    }

    @Test func stripANSIHandlesOSCWithStringTerminator() {
        #expect(LineSplitter.stripANSI("\u{1B}]0;title\u{1B}\\hello") == "hello")
        #expect(LineSplitter.stripANSI("\u{1B}]8;;http://x\u{07}link") == "link")
    }
}
