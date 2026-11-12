import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

/// `container clean` (1.7+): the probe, the argv, and the two failures the CLI words badly.
@Suite("CLIBackend clean")
struct CLIBackendCleanTests {
    /// What 1.7.1 printed for a stopped container, after `Error: ` was stripped.
    static let notRunning =
        "internalError: \"failed to clean container\" (cause: \"invalidState: \"container is not running\"\")"

    @Test func probeAgainstBothReleases() async throws {
        let help = FixtureSet.cli171.text("clean-help.txt")
        let new = RecordingRunner { _ in ProcessResult(stdout: help) }
        let newBackend = try CLIBackend.recording(new)
        #expect(await newBackend.supportsClean())
        #expect(await newBackend.supportsClean())
        #expect(new.commands == [["clean", "--help"]])  // cached

        // CLI 1.5.0 has no such command: usage exit code 64.
        let old = RecordingRunner { _ in
            ProcessResult(exitCode: 64, stdout: "", stderr: "Error: unknown command 'clean'\n")
        }
        let oldBackend = try CLIBackend.recording(old)
        #expect(await !oldBackend.supportsClean())
        #expect(await !oldBackend.supportsClean())
        #expect(old.commands == [["clean", "--help"]])  // one probe, no `system status` follow-up
    }

    @Test func argvOutputAndValidation() async throws {
        let runner = RecordingRunner(streamLines: [OutputLine("web"), OutputLine("db")])
        let backend = try CLIBackend.recording(runner)
        let result = await drain(backend.cleanContainers(["web", "db"]))
        #expect(result.error == nil)
        #expect(result.lines.map(\.text) == ["web", "db"])
        #expect(runner.commands == [["clean", "--", "web", "db"]])
        #expect(runner.calls[0].streamed)
        #expect(await drain(backend.cleanContainers([])).error != nil)
        #expect(await drain(backend.cleanContainers(["web", "--debug"])).error != nil)
        #expect(runner.calls.count == 1)
        #expect(CLIBackend.cleanCommandPreview(["web", "my db"]) == "container clean -- web 'my db'")
    }

    @Test func failuresAreWorded() async throws {
        let stopped = BackendError.commandFailed(
            command: "container clean -- web", exitCode: 1, message: Self.notRunning)
        guard case .commandFailed(let command, 1, let message) = CLIBackend.cleanFailure(stopped) as? BackendError
        else {
            Issue.record("expected commandFailed")
            return
        }
        #expect(command == "container clean -- web")
        #expect(message.hasPrefix("Disk space can only be reclaimed from a running container."))
        #expect(message.contains("container is not running"))

        let unknown = BackendError.commandFailed(command: "c", exitCode: 64, message: "unknown command 'clean'")
        guard case .unsupported(let feature, _) = CLIBackend.cleanFailure(unknown) as? BackendError else {
            Issue.record("expected unsupported")
            return
        }
        #expect(feature == "Reclaim Disk Space")

        let other = BackendError.notFound(kind: "container", id: "ghost")
        #expect(CLIBackend.cleanFailure(other) as? BackendError == other)
    }

    /// The CLI's "not found" for one of several ids reaches the caller as `.notFound`, through the stream.
    @Test func aMissingContainerIsNotFound() async throws {
        let failure = BackendError.commandFailed(
            command: "container clean -- ghost", exitCode: 1,
            message: "internalError: \"failed to clean container\" (cause: \"notFound: \"container with ID ghost "
                + "not found\"\")")
        let backend = try CLIBackend.recording(RecordingRunner(streamError: failure))
        let result = await drain(backend.cleanContainers(["ghost"]))
        #expect(result.error as? BackendError == .notFound(kind: "container", id: "ghost"))
    }

    @Test func mockPlaysBothReleases() async throws {
        let modern = MockBackend(kubernetes: .modern)
        #expect(await modern.supportsClean())
        let running = try #require(try await modern.listContainers(includeStopped: false).first)
        let stopped = try #require(try await modern.listContainers(includeStopped: true).first { !$0.isRunning })
        let ok = await drain(modern.cleanContainers([running.id]))
        #expect(ok.error == nil)
        #expect(ok.lines.map(\.text) == [running.id])
        #expect(await modern.cleanedContainers == [running.id])
        // Nothing is removed: the container list is what it was.
        #expect(try await modern.listContainers(includeStopped: false).contains { $0.id == running.id })

        let refused = await drain(modern.cleanContainers([stopped.id, running.id]))
        #expect(refused.lines.map(\.text) == [running.id])  // the running one is still cleaned
        #expect((refused.error as? BackendError)?.errorDescription?.contains("running container") == true)
        let missing = await drain(modern.cleanContainers(["ghost"]))
        #expect(missing.error as? BackendError == .notFound(kind: "container", id: "ghost"))

        let legacy = MockBackend(kubernetes: .legacy)
        #expect(await !legacy.supportsClean())
        guard case .unsupported = await drain(legacy.cleanContainers([running.id])).error as? BackendError else {
            Issue.record("expected unsupported on a mock that plays 1.5.0")
            return
        }
    }
}
