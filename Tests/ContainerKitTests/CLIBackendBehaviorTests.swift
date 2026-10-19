import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

@Suite("CLIBackend behavior")
struct CLIBackendBehaviorTests {
    static let down = "Error: apiserver is not running and not registered with launchd\n"
    static let plugins = "Error: Plugins are unavailable. Start the container system services and retry\n"

    @Test func configRoundTripCreatesDirectory() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cd-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("nested/config.toml").path
        let backend = try CLIBackend.recording(RecordingRunner(), configPath: path)
        #expect(try await backend.readConfigTOML() == "")
        let text = "[dns]\ndomain = \"test\"\n\n[container]\ncpus = 4\n"
        try await backend.writeConfigTOML(text)
        #expect(try await backend.readConfigTOML() == text)
        try await backend.writeConfigTOML("")
        #expect(try await backend.readConfigTOML() == "")
    }

    @Test func configPathHonorsEnvironmentOverride() {
        #expect(
            CLIBackend.configFileURL(environment: ["CONTAINER_CONFIG_PATH": "/tmp/x/config.toml"]).path
                == "/tmp/x/config.toml")
        #expect(CLIBackend.configFileURL(environment: [:]).path.hasSuffix("/.config/container/config.toml"))
    }

    @Test func systemStatusReturnsStoppedWhenServicesAreDown() async throws {
        let runner = RecordingRunner { args in
            args.contains("--version")
                ? ProcessResult(stdout: "container CLI version 1.5.0 (build: release, commit: d265d66)\n")
                : ProcessResult(exitCode: 1, stdout: "", stderr: Self.down)
        }
        let status = try await CLIBackend.recording(runner).systemStatus()
        #expect(!status.isRunning)
        #expect(status.status == "stopped")
        #expect(status.client?.version == "1.5.0")
    }

    @Test func pluginsUnavailableBecomesSystemNotRunningWhenStatusFails() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 1, stdout: "", stderr: Self.plugins) }
        await #expect(throws: BackendError.systemNotRunning) { _ = try await CLIBackend.recording(runner).listImages() }
        #expect(runner.commands == [["image", "ls", "--format", "json"], ["system", "status"]])
    }

    @Test func pluginsUnavailableStaysCommandFailedWhenSystemIsUp() async throws {
        let runner = RecordingRunner { args in
            args.contains("status")
                ? ProcessResult(stdout: "running") : ProcessResult(exitCode: 1, stdout: "", stderr: Self.plugins)
        }
        await #expect {
            _ = try await CLIBackend.recording(runner).listImages()
        } throws: { error in
            guard case BackendError.commandFailed(let command, 1, let message) = error else { return false }
            return command == "/usr/local/bin/container image ls --format json"
                && message.hasPrefix("Plugins are unavailable")
        }
    }

    @Test func execReturnsTheProgramsOwnErrorOutput() async throws {
        let runner = RecordingRunner { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "Error: config not found: x\n")
        }
        let result = try await CLIBackend.recording(runner).execCapture("web", command: ["app"], workingDirectory: nil)
        #expect(result.exitCode == 1)
        #expect(result.stderr == "Error: config not found: x\n")
    }

    @Test func execMissingContainerThrowsNotFound() async throws {
        let runner = RecordingRunner { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "Error: get failed: container web not found\n")
        }
        await #expect(throws: BackendError.notFound(kind: "container", id: "web")) {
            _ = try await CLIBackend.recording(runner).execCapture("web", command: ["ls"], workingDirectory: nil)
        }
    }

    @Test func execOtherContainerNotFoundIsProgramOutput() async throws {
        // `web` is running; the program inside reports a *different* missing container.
        let runner = RecordingRunner { _ in
            ProcessResult(exitCode: 2, stdout: "", stderr: "Error: get failed: container web2 not found\n")
        }
        let result = try await CLIBackend.recording(runner).execCapture("web", command: ["ls"], workingDirectory: nil)
        #expect(result.exitCode == 2)
    }

    @Test func execSystemDownThrows() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 1, stdout: "", stderr: Self.down) }
        await #expect(throws: BackendError.systemNotRunning) {
            _ = try await CLIBackend.recording(runner).execCapture("web", command: ["ls"], workingDirectory: nil)
        }
    }

    @Test func createContainerWithoutIdOrNameThrowsDecoding() async throws {
        let runner = RecordingRunner { _ in ProcessResult(stdout: "\n") }
        await #expect {
            _ = try await CLIBackend.recording(runner).createContainer(RunSpec(image: "alpine"))
        } throws: { error in
            if case BackendError.decoding = error { return true }
            return false
        }
    }

    @Test func inspectMissingMapsToNotFound() async throws {
        let runner = RecordingRunner { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "Error: container not found: ghost\n")
        }
        await #expect(throws: BackendError.notFound(kind: "container", id: "ghost")) {
            _ = try await CLIBackend.recording(runner).inspectContainer("ghost")
        }
    }

    @Test func emptyInspectArrayMapsToNotFound() async throws {
        let runner = RecordingRunner { _ in ProcessResult(stdout: "[]") }
        await #expect(throws: BackendError.notFound(kind: "volume", id: "v")) {
            _ = try await CLIBackend.recording(runner).inspectVolume("v")
        }
    }

    @Test func garbageJSONIsADecodingError() async throws {
        let runner = RecordingRunner { _ in ProcessResult(stdout: "not json") }
        await #expect {
            _ = try await CLIBackend.recording(runner).listContainers(includeStopped: true)
        } throws: { error in
            if case BackendError.decoding(let command, _) = error { return command.hasSuffix("ls -a --format json") }
            return false
        }
    }

    @Test func listsDecodeFixtures() async throws {
        let runner = RecordingRunner { args in
            switch args[1] {
            case "ls": ProcessResult(stdout: Fixtures.data("containers.json"))
            case "stats": ProcessResult(stdout: Fixtures.data("stats.json"))
            default: ProcessResult(stdout: Fixtures.data("builder.json"))
            }
        }
        let backend = try CLIBackend.recording(runner)
        #expect(try await backend.listContainers(includeStopped: true).contains { $0.id == "probe" })
        #expect(try await backend.containerStats(ids: []).count == 2)
        #expect(try await backend.builderStatus()?.isBuilder == true)
    }

    @Test func streamFailureIsRemapped() async throws {
        let failure = BackendError.commandFailed(
            command: "container logs ghost", exitCode: 1,
            message:
                "failed to get logs for container ghost (cause: \"notFound: \"container with ID ghost not found\"\")")
        let runner = RecordingRunner(streamLines: [OutputLine("partial")], streamError: failure)
        let (lines, error) = await drain(
            try CLIBackend.recording(runner).containerLogs("ghost", follow: false, boot: false, tail: nil))
        #expect(lines.map(\.text) == ["partial"])
        #expect(error as? BackendError == .notFound(kind: "container", id: "ghost"))
    }

    @Test func execCaptureReturnsCommandExitCode() async throws {
        let runner = RecordingRunner { _ in
            ProcessResult(exitCode: 2, stdout: "", stderr: "ls: /nope: No such file or directory\n")
        }
        let result = try await CLIBackend.recording(runner).execCapture(
            "web", command: ["ls", "/nope"], workingDirectory: nil)
        #expect(result.exitCode == 2)
        #expect(result.stderr.contains("No such file"))
    }

    @Test func execCaptureThrowsForMissingContainer() async throws {
        let runner = RecordingRunner { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "Error: container not found: ghost\n")
        }
        await #expect(throws: BackendError.notFound(kind: "container", id: "ghost")) {
            _ = try await CLIBackend.recording(runner).execCapture("ghost", command: ["true"], workingDirectory: nil)
        }
    }

    @Test func adminCancelMapsToCancelled() async throws {
        let runner = RecordingRunner { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "0:98: execution error: User canceled. (-128)\n")
        }
        await #expect(throws: BackendError.cancelled) {
            try await CLIBackend.recording(runner).createDNSDomain("test", localhostAddress: nil)
        }
    }

    @Test func adminFailureCarriesShellMessage() async throws {
        let runner = RecordingRunner { _ in
            ProcessResult(
                exitCode: 1, stdout: "", stderr: "0:98: execution error: Error: domain already exists: test (1)\n")
        }
        await #expect {
            try await CLIBackend.recording(runner).createDNSDomain("test", localhostAddress: nil)
        } throws: { error in
            guard case BackendError.commandFailed(_, _, let message) = error else { return false }
            return message == "domain already exists: test (1)"
        }
    }

    @Test func kubernetesUnavailableOnlyWhenPluginIsMissing() async throws {
        let runner = RecordingRunner { args in
            args.contains("status")
                ? ProcessResult(stdout: "running")
                : ProcessResult(exitCode: 64, stdout: "", stderr: "Error: unknown command 'k8s'\n")
        }
        let backend = try CLIBackend.recording(runner)
        #expect(try await !backend.checkKubernetesAvailable())
        #expect(await !backend.kubernetesAvailable())
        #expect(runner.commands.prefix(2) == [["k8s", "--help"], ["system", "status"]])
    }

    @Test func kubernetesAvailabilityThrowsWhenSystemIsDown() async throws {
        let runner = RecordingRunner { _ in
            ProcessResult(exitCode: 64, stdout: "", stderr: "Error: unknown command 'k8s'\n")
        }
        await #expect(throws: BackendError.systemNotRunning) {
            _ = try await CLIBackend.recording(runner).checkKubernetesAvailable()
        }
        let down = RecordingRunner { _ in ProcessResult(exitCode: 1, stdout: "", stderr: Self.down) }
        await #expect(throws: BackendError.systemNotRunning) {
            _ = try await CLIBackend.recording(down).checkKubernetesAvailable()
        }
    }

    @Test func systemLogsWindowScalesWithRequest() async throws {
        let runner = RecordingRunner { _ in ProcessResult(stdout: "a\nb\n") }
        let backend = try CLIBackend.recording(runner)
        _ = try await backend.systemLogs(lines: 200)
        _ = try await backend.systemLogs(lines: 501)
        #expect(runner.commands == [["system", "logs", "--last", "5m"], ["system", "logs", "--last", "1h"]])
    }

    @Test func cancelledTextOutsideOsascriptIsNotCancellation() {
        #expect(
            CLIErrorMapper.map(
                command: "container image pull x", exitCode: 1, stderr: "Error: User canceled the job (-128)\n")
                != .cancelled)
    }

    @Test func adminPromptDismissalIsCancellation() async throws {
        let runner = RecordingRunner { _ in
            ProcessResult(exitCode: 1, stdout: "", stderr: "0:120: execution error: User canceled. (-128)\n")
        }
        await #expect(throws: BackendError.cancelled) { try await CLIBackend.recording(runner).deleteDNSDomain("test") }
    }

    @Test func writeConfigFollowsSymlinkAndKeepsPermissions() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("cd-config-link-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("dotfiles"), withIntermediateDirectories: true)
        let real = dir.appendingPathComponent("dotfiles/config.toml")
        try Data("old\n".utf8).write(to: real)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        let link = dir.appendingPathComponent("config.toml")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let backend = try CLIBackend.recording(RecordingRunner(), configPath: link.path)
        try await backend.writeConfigTOML("new\n")
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try String(contentsOf: real, encoding: .utf8) == "new\n")
        #expect((try fm.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func missingExplicitExecutableStillConstructs() throws {
        // Explicit paths are trusted (the UI may point at a custom build); discovery only applies to nil.
        let backend = try CLIBackend(executable: "/opt/custom/container", runner: RecordingRunner())
        #expect(backend.backendDescription == "CLI (/opt/custom/container)")
    }
}
