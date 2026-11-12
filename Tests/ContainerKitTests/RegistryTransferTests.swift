import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

/// Push, pull and login against a registry: the `--scheme` argument and the explanations for the failures
/// container 1.7.1 produced against a local `registry:2` (recorded on 2026-11-12, quoted verbatim below).
@Suite("Registry transfers and failures")
struct RegistryTransferTests {
    // What the CLI printed, after `Error: ` was stripped.
    static let wrongScheme = "-9836: bad protocol version"
    static let refused = "POSIXErrorCode(rawValue: 61): Connection refused"
    static let unresolved = "failed to resolve either repository hostname cd-it-reg-nohost.invalid"
    static let insecureLogin =
        "refusing insecure credential exchange: registry 127.0.0.1 issued an authentication challenge over an "
        + "insecure connection"
    static let missingPlatform =
        "content with digest sha256:350f747a86e8774d359a4f452dec12a2585e73bf072e71c5f628455843b88c71"

    // MARK: argv

    @Test func schemeIsPassedToPushAndPull() async throws {
        let runner = RecordingRunner()
        let backend = try CLIBackend.recording(runner)
        _ = await drain(backend.pushImage("localhost:5000/app:1", platform: .arm64, scheme: "http"))
        _ = await drain(backend.pullImage("localhost:5000/app:1", platform: nil, scheme: "http"))
        _ = await drain(backend.pushImage("ghcr.io/x/y:1", platform: nil, scheme: nil))
        _ = await drain(backend.pullImage("alpine", platform: .amd64))
        #expect(
            runner.commands == [
                [
                    "image", "push", "--scheme", "http", "--progress", "plain", "--platform", "linux/arm64", "--",
                    "localhost:5000/app:1",
                ],
                ["image", "pull", "--scheme", "http", "--progress", "plain", "--", "localhost:5000/app:1"],
                ["image", "push", "--progress", "plain", "--", "ghcr.io/x/y:1"],
                ["image", "pull", "--progress", "plain", "--platform", "linux/amd64", "--", "alpine"],
            ])
        #expect(runner.calls.filter(\.streamed).count == 4)
    }

    @Test func anUnknownSchemeNeverReachesTheCLI() async throws {
        let runner = RecordingRunner()
        let backend = try CLIBackend.recording(runner)
        #expect(await drain(backend.pushImage("localhost:5000/a:1", platform: nil, scheme: "ftp")).error != nil)
        #expect(await drain(backend.pullImage("localhost:5000/a:1", platform: nil, scheme: "--debug")).error != nil)
        await #expect(throws: BackendError.self) {
            try await backend.registryLogin(server: "localhost:5000", username: "u", password: "p", scheme: "ftp")
        }
        #expect(runner.calls.isEmpty)
    }

    // MARK: Explanations

    @Test func hostOfAReference() {
        #expect(RegistryFailure.host(ofReference: "127.0.0.1:5057/cd-it-reg/alpine:test") == "127.0.0.1:5057")
        #expect(RegistryFailure.host(ofReference: "localhost/app") == "localhost")
        #expect(RegistryFailure.host(ofReference: "ghcr.io/x/y:1") == "ghcr.io")
        #expect(RegistryFailure.host(ofReference: "library/alpine") == nil)
        #expect(RegistryFailure.host(ofReference: "alpine:3.22") == nil)
    }

    @Test func everySeenFailureSaysWhatToDo() {
        func text(_ message: String, _ action: RegistryFailure.Action, platform: Platform? = .arm64) -> String {
            RegistryFailure.explanation(of: message, host: "127.0.0.1:5057", action: action, platform: platform) ?? ""
        }
        #expect(text(Self.wrongScheme, .push).contains("choose HTTP as the connection"))
        #expect(text(Self.wrongScheme, .pull).hasSuffix("(-9836: bad protocol version)"))
        #expect(text(Self.refused, .push).contains("Nothing answers at 127.0.0.1:5057"))
        #expect(text(Self.unresolved, .pull).contains("could not be found"))
        #expect(text(Self.insecureLogin, .login).contains("Log in over HTTPS"))
        #expect(text(Self.insecureLogin, .push).contains("Use HTTPS for a registry that needs a login"))
        #expect(text(Self.missingPlatform, .push, platform: nil).contains("Choose a single platform"))
        // With a platform chosen, or for a pull, the digest message is not ours to explain.
        #expect(
            RegistryFailure.explanation(of: Self.missingPlatform, host: nil, action: .push, platform: .arm64) == nil)
        #expect(RegistryFailure.explanation(of: Self.missingPlatform, host: nil, action: .pull) == nil)
        #expect(RegistryFailure.explanation(of: "image not found", host: nil, action: .pull) == nil)
        // Read from the 1.7.1 binary, not produced live.
        #expect(text("access denied or wrong credentials", .login).contains("did not accept the user name or password"))
        #expect(text("-9807: invalid certificate chain", .pull).contains("certificate may not be trusted"))
        // Without a host in the reference the sentence still reads.
        let noHost = RegistryFailure.explanation(of: Self.refused, host: nil, action: .pull)
        #expect(noHost?.hasPrefix("Nothing answers at The registry") == true)
    }

    @Test func aFailedPushEndsWithTheExplanationNotTheProgressLines() async throws {
        // stderr of a real `image push` to a plain-HTTP registry over HTTPS: 43 progress lines, then the error.
        let stderr =
            (25...43).map { "Pushing image 127.0.0.1:5057/cd-it-reg/alpine:test 0% [\($0)s]" }
            + ["Error: \(Self.wrongScheme)"]
        let cleaned = CLIErrorMapper.cleanMessage(stderr.joined(separator: "\n"))
        #expect(cleaned == Self.wrongScheme)
        #expect(CLIErrorMapper.isProgressLine("Pushing image a/b:1 100% (4 blobs, 4.0 MB) [0s]"))
        #expect(CLIErrorMapper.isProgressLine("[1/2] Fetching image [41s]"))
        #expect(!CLIErrorMapper.isProgressLine("failed to resolve [host]"))
        #expect(!CLIErrorMapper.isProgressLine("Error: something [ok]"))

        let failure = BackendError.commandFailed(command: "container image push …", exitCode: 1, message: cleaned)
        let backend = try CLIBackend.recording(RecordingRunner(streamError: failure))
        let result = await drain(
            backend.pushImage("127.0.0.1:5057/cd-it-reg/alpine:test", platform: .arm64, scheme: nil))
        guard case .commandFailed(let command, 1, let message) = result.error as? BackendError else {
            Issue.record("expected commandFailed, got \(String(describing: result.error))")
            return
        }
        #expect(command == "container image push …")
        #expect(message.hasPrefix("127.0.0.1:5057 did not answer with HTTPS."))
        #expect(message.contains("choose HTTP as the connection"))
    }

    @Test func aFailedLoginIsExplainedAndNeverShowsThePassword() async throws {
        let secret = "s3cr3t-\(UUID().uuidString)"
        let runner = RecordingRunner { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "Error: \(Self.insecureLogin)\n")
        }
        let backend = try CLIBackend.recording(runner)
        let error = await backendError {
            try await backend.registryLogin(
                server: "127.0.0.1:5058", username: "cdit", password: secret, scheme: "http")
        }
        guard case .commandFailed(let command, 1, let message) = error else {
            Issue.record("expected commandFailed, got \(String(describing: error))")
            return
        }
        #expect(message.hasPrefix("127.0.0.1:5058 asks for a login"))
        #expect(!message.contains(secret) && !command.contains(secret))
        #expect(!String(describing: error).contains(secret))
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].stdin == Data((secret + "\n").utf8))
        #expect(!runner.calls[0].arguments.contains { $0.contains(secret) })
    }

    // MARK: Recorded listing

    /// `registry list --format json` with one login, recorded from 1.7.1 (user name replaced with `user`).
    @Test func registryListWithALoginDecodes() {
        let logins = CLIOutputParsing.registries(FixtureSet.cli171.data("registries-login.json"))
        #expect(logins == [RegistryLogin(server: "127.0.0.1:5057", username: "user")])
    }

    private func backendError(_ body: () async throws -> Void) async -> BackendError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? BackendError
        }
    }
}
