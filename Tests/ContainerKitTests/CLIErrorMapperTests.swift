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
