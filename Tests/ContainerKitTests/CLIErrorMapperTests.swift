import Foundation
import Testing

@testable import ContainerKit

@Suite("CLIErrorMapper")
struct CLIErrorMapperTests {
    @Test func xpcConnectionInvalidMeansSystemNotRunning() {
        let stderr = """
            Error: interrupted: "XPC connection error: Connection invalid"
            Ensure container system service has been started with `container system start`.
            """
        #expect(CLIErrorMapper.map(command: "container image ls", exitCode: 1, stderr: stderr) == .systemNotRunning)
    }

    @Test func systemNotRunning() {
        let stderr = "Error: apiserver is not running and not registered with launchd\n"
        #expect(
            CLIErrorMapper.map(command: "container system status", exitCode: 1, stderr: stderr) == .systemNotRunning)
    }

    @Test func pluginsUnavailableIsAmbiguousUntilProbed() {
        let stderr = "Error: Plugins are unavailable. Start the container system services and retry\n"
        #expect(CLIErrorMapper.isPluginsUnavailable(stderr))
        guard
            case .commandFailed(_, 1, let message) = CLIErrorMapper.map(
                command: "container ls", exitCode: 1, stderr: stderr)
        else {
            Issue.record("expected commandFailed"); return
        }
        #expect(message == "Plugins are unavailable. Start the container system services and retry")
    }

    @Test(arguments: [
        ("Error: container not found: nope-xyz", "container", "nope-xyz"),
        ("Error: image not found: nope-xyz:1", "image", "nope-xyz:1"),
        ("Error: volume not found: nopevol", "volume", "nopevol"),
        ("Error: network not found: nopenet", "network", "nopenet"),
        // Recorded from container 1.7.1: `commit` of a missing container, and stop / start of one.
        ("Error: get failed: container cd-it-ghost-1 not found", "container", "cd-it-ghost-1"),
        (#"Error: notFound: "container with ID cd-it-ghost-2 not found""#, "container", "cd-it-ghost-2"),
        ("Error: container with ID cd-it-ghost-3 not found", "container", "cd-it-ghost-3"),
        (
            #"Error: failed to inspect container machine (cause: "notFound: "container machine with ID nopem not found"")"#,
            "machine", "nopem"
        ),
        (
            #"Error: internalError: "failed to stop container" (cause: "notFound: "container with ID web not found"")"#,
            "container", "web"
        ),
    ])
    func notFound(stderr: String, kind: String, id: String) {
        #expect(CLIErrorMapper.map(command: "x", exitCode: 1, stderr: stderr) == .notFound(kind: kind, id: id))
    }

    /// container 1.7.1, `image save` of all platforms when only this Mac's was pulled: the CLI's whole message is
    /// `content with digest sha256:…`.
    @Test func savingAllPlatformsOfAPartlyPulledImageIsExplained() async throws {
        let stderr =
            "Error: content with digest sha256:350f747a86e8774d359a4f452dec12a2585e73bf072e71c5f628455843b88c71\n"
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 1, stdout: "", stderr: stderr) }
        let backend = try CLIBackend.recording(runner)
        do {
            try await backend.saveImages(["alpine:latest"], to: "/tmp/a.tar", platform: nil)
            Issue.record("save must fail")
        } catch let error as BackendError {
            guard case .commandFailed(let command, 1, let message) = error else {
                Issue.record("expected commandFailed, got \(error)")
                return
            }
            #expect(command.hasSuffix("image save --output /tmp/a.tar -- alpine:latest"))
            #expect(message.hasPrefix("content with digest sha256:350f747a86e8"))
            #expect(message.contains("“All platforms” cannot be saved. Choose a single platform"))
        }
        // With a platform chosen the CLI's message is passed on unchanged.
        let plain = CLIErrorMapper.map(command: "c", exitCode: 1, stderr: stderr)
        #expect(CLIBackend.saveFailure(plain, platform: .arm64) == plain)
        #expect(CLIBackend.saveFailure(.systemNotRunning, platform: nil) == .systemNotRunning)
    }

    @Test func cleansProgressNoiseAndPrefix() {
        let stderr =
            "[1/6] Fetching image [0s]\n\u{1B}[2K[2/6] Unpacking [1s]\r\nError: failed to pull image: unauthorized\n\n"
        let error = CLIErrorMapper.map(command: "container image pull x", exitCode: 1, stderr: stderr)
        #expect(
            error
                == .commandFailed(
                    command: "container image pull x", exitCode: 1, message: "failed to pull image: unauthorized"))
    }

    @Test func fallsBackToStdoutWhenStderrIsEmpty() {
        let error = CLIErrorMapper.map(
            command: "c", exitCode: 2, stderr: "  \n", stdout: "Error: something on stdout\n")
        #expect(error == .commandFailed(command: "c", exitCode: 2, message: "something on stdout"))
    }

    @Test func userCancelledAdminPrompt() {
        let stderr = "0:120: execution error: User canceled. (-128)\n"
        #expect(CLIErrorMapper.indicatesUserCancelled(stderr))
    }

    @Test func progressLineDetection() {
        #expect(CLIErrorMapper.isProgressLine("[3/6] Fetching kernel [0s]"))
        #expect(CLIErrorMapper.isProgressLine("  [10/12] x"))
        #expect(!CLIErrorMapper.isProgressLine("[INFO] something"))
        #expect(!CLIErrorMapper.isProgressLine("[1/] x"))
        #expect(!CLIErrorMapper.isProgressLine("plain text"))
    }
}
