import Foundation

// The backend contract. Every UI feature talks to these protocols only, never to the CLI directly.
// Implementations: `CLIBackend` (ships first, wraps /usr/local/bin/container), `MockBackend`
// (fixtures, for previews/tests), and a future `XPCBackend` (links Apple's ContainerAPIClient).
//
// Rules for implementers:
//  * All methods are safe to call from any actor; they do their own serialization.
//  * Long-running actions stream `OutputLine`s and finish by throwing or completing the stream.
//  * Errors are `BackendError`; wrap anything else.

public typealias LineStream = AsyncThrowingStream<OutputLine, any Error>

public protocol SystemBackend: Sendable {
    func systemStatus() async throws -> SystemStatus
    func systemStart() async throws
    func systemStop() async throws
    func systemProperties() async throws -> SystemProperties
    func diskUsage() async throws -> DiskUsage
    /// Tail of the unified log for the container services.
    func systemLogs(lines: Int) async throws -> [OutputLine]
    func listDNSDomains() async throws -> [DNSDomain]
    /// Requires administrator rights; implementations prompt via Authorization Services / osascript.
    func createDNSDomain(_ domain: String, localhostAddress: String?) async throws
    func deleteDNSDomain(_ domain: String) async throws
    /// Raw `~/.config/container/config.toml` (empty string when the file does not exist).
    func readConfigTOML() async throws -> String
    func writeConfigTOML(_ text: String) async throws
}

public protocol ContainerOperations: Sendable {
    func listContainers(includeStopped: Bool) async throws -> [Container]
    func inspectContainer(_ id: String) async throws -> Container
    /// Returns the new container id. Streams `container run` output for `detach == false`.
    func runContainer(_ spec: RunSpec) -> LineStream
    func createContainer(_ spec: RunSpec) async throws -> String
    func startContainer(_ id: String) async throws
    func stopContainer(_ id: String, timeoutSeconds: Int?, signal: String?) async throws
    func killContainer(_ id: String, signal: String?) async throws
    func deleteContainer(_ id: String, force: Bool) async throws
    func pruneContainers() async throws
    /// `container logs`. `follow` keeps the stream open; `boot` returns the VM boot log instead.
    func containerLogs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> LineStream
    func containerStats(ids: [String]) async throws -> [ContainerStats]
    /// Runs a command to completion and returns its output (non-interactive).
    func execCapture(_ id: String, command: [String], workingDirectory: String?) async throws -> (exitCode: Int32, stdout: String, stderr: String)
    /// `container cp` — either side may be `<container>:<path>`.
    func copy(from source: String, to destination: String) async throws
    func exportContainer(_ id: String, to tarPath: String) async throws
    /// Command line an embedded terminal should spawn for an interactive session.
    func terminalCommand(for target: TerminalTarget) -> CommandLine
}

public protocol ImageOperations: Sendable {
    func listImages() async throws -> [Image]
    func inspectImage(_ reference: String) async throws -> Image
    func pullImage(_ reference: String, platform: Platform?) -> LineStream
    func pushImage(_ reference: String, platform: Platform?) -> LineStream
    func deleteImage(_ reference: String) async throws
    func tagImage(_ reference: String, newReference: String) async throws
    func pruneImages(all: Bool) async throws
    func saveImages(_ references: [String], to tarPath: String, platform: Platform?) async throws
    func loadImages(from tarPath: String) async throws
    func buildImage(_ spec: BuildSpec) -> LineStream
    func builderStatus() async throws -> Container?
    func builderStart(cpus: Int?, memory: MemorySize?) async throws
    func builderStop() async throws
    func builderDelete() async throws
}

public protocol VolumeOperations: Sendable {
    func listVolumes() async throws -> [Volume]
    func inspectVolume(_ name: String) async throws -> Volume
    func createVolume(name: String, size: MemorySize?, journal: String?, labels: [String: String]) async throws
    func deleteVolume(_ name: String) async throws
    func pruneVolumes() async throws
}

public protocol NetworkOperations: Sendable {
    func listNetworks() async throws -> [Network]
    func inspectNetwork(_ name: String) async throws -> Network
    func createNetwork(name: String, subnet: String?, subnetV6: String?, labels: [String: String]) async throws
    func deleteNetwork(_ name: String) async throws
    func pruneNetworks() async throws
}

public protocol RegistryOperations: Sendable {
    func listRegistries() async throws -> [RegistryLogin]
    /// Password is passed on stdin, never as an argument.
    func registryLogin(server: String, username: String, password: String, scheme: String?) async throws
    func registryLogout(server: String) async throws
}

public protocol MachineOperations: Sendable {
    func listMachines() async throws -> [Machine]
    func inspectMachine(_ name: String) async throws -> Machine
    func createMachine(_ spec: MachineSpec) -> LineStream
    func stopMachine(_ name: String) async throws
    func deleteMachine(_ name: String) async throws
    func setDefaultMachine(_ name: String) async throws
    /// `container machine set -n NAME key=value …` (applies after the next boot).
    func configureMachine(_ name: String, settings: [String: String]) async throws
    func machineLogs(_ name: String) async throws -> [OutputLine]
}

public protocol KubernetesOperations: Sendable {
    /// Whether the `k8s` plugin exists in this CLI build. Returns `false` **only** when the plugin is missing;
    /// throws `BackendError.systemNotRunning` when the container system is down (and other errors as usual),
    /// which the UI should treat as "unknown" rather than "unavailable".
    func checkKubernetesAvailable() async throws -> Bool
    /// Deprecated non-throwing form of `checkKubernetesAvailable()`: any error reads as `false`.
    func kubernetesAvailable() async -> Bool
    func listClusters() async throws -> [KubernetesCluster]
    func createCluster(_ spec: ClusterSpec) -> LineStream
    func deleteCluster(_ name: String) async throws
    func loadImage(_ reference: String, intoCluster cluster: String?, nodes: [String], platform: Platform?) -> LineStream
}

extension KubernetesOperations {
    /// Default for conformers that only implement `kubernetesAvailable()`.
    public func checkKubernetesAvailable() async throws -> Bool { await kubernetesAvailable() }
}

/// The complete backend.
public protocol ContainerBackend:
    SystemBackend, ContainerOperations, ImageOperations, VolumeOperations,
    NetworkOperations, RegistryOperations, MachineOperations, KubernetesOperations {
    /// Human-readable backend name for the About/diagnostics screens (`CLI 1.5.0`, `Mock`, `XPC`).
    var backendDescription: String { get }
}

// MARK: - Errors

public enum BackendError: Error, LocalizedError, Hashable, Sendable {
    /// `container-apiserver` is not running. UI shows the "Start container system" screen.
    case systemNotRunning
    /// `/usr/local/bin/container` missing. UI shows install instructions.
    case cliNotInstalled(searchedPaths: [String])
    /// The CLI exited non-zero. `message` is the cleaned stderr (without progress noise).
    case commandFailed(command: String, exitCode: Int32, message: String)
    case notFound(kind: String, id: String)
    case decoding(command: String, underlying: String)
    case unsupported(feature: String, reason: String)
    case cancelled
    case permissionDenied(String)
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .systemNotRunning: return "The container system is not running."
        case .cliNotInstalled(let paths): return "The `container` command was not found (looked in \(paths.joined(separator: ", "))). Install it from github.com/apple/container/releases."
        case .commandFailed(let command, let code, let message): return message.isEmpty ? "`\(command)` failed with exit code \(code)." : message
        case .notFound(let kind, let id): return "\(kind.capitalized) “\(id)” was not found."
        case .decoding(let command, let underlying): return "Could not read the output of `\(command)`: \(underlying)"
        case .unsupported(let feature, let reason): return "\(feature) is not available: \(reason)"
        case .cancelled: return "Cancelled."
        case .permissionDenied(let what): return "Permission denied: \(what)"
        case .other(let message): return message
        }
    }
}
