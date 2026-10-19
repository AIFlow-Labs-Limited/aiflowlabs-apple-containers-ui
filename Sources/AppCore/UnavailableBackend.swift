import ContainerKit
import Foundation

/// Placeholder backend used when the `container` CLI is not installed. Every call throws
/// `cliNotInstalled`, so stores stay empty and the UI shows the install screen.
public struct UnavailableBackend: ContainerBackend {
    public let searchedPaths: [String]
    public var backendDescription: String { "Unavailable (container CLI not found)" }

    public init(searchedPaths: [String]) { self.searchedPaths = searchedPaths }

    private var error: BackendError { .cliNotInstalled(searchedPaths: searchedPaths) }
    private func fail() -> LineStream { let e = error; return AsyncThrowingStream { $0.finish(throwing: e) } }

    // MARK: System
    public func systemStatus() async throws -> SystemStatus { throw error }
    public func systemStart() async throws { throw error }
    public func systemStop() async throws { throw error }
    public func systemProperties() async throws -> SystemProperties { throw error }
    public func diskUsage() async throws -> DiskUsage { throw error }
    public func systemLogs(lines: Int) async throws -> [OutputLine] { throw error }
    public func listDNSDomains() async throws -> [DNSDomain] { throw error }
    public func createDNSDomain(_ domain: String, localhostAddress: String?) async throws { throw error }
    public func deleteDNSDomain(_ domain: String) async throws { throw error }
    public func readConfigTOML() async throws -> String { throw error }
    public func writeConfigTOML(_ text: String) async throws { throw error }

    // MARK: Containers
    public func listContainers(includeStopped: Bool) async throws -> [Container] { throw error }
    public func inspectContainer(_ id: String) async throws -> Container { throw error }
    public func runContainer(_ spec: RunSpec) -> LineStream { fail() }
    public func createContainer(_ spec: RunSpec) async throws -> String { throw error }
    public func startContainer(_ id: String) async throws { throw error }
    public func stopContainer(_ id: String, timeoutSeconds: Int?, signal: String?) async throws { throw error }
    public func killContainer(_ id: String, signal: String?) async throws { throw error }
    public func deleteContainer(_ id: String, force: Bool) async throws { throw error }
    public func pruneContainers() async throws { throw error }
    public func containerLogs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> LineStream { fail() }
    public func containerStats(ids: [String]) async throws -> [ContainerStats] { throw error }
    public func execCapture(
        _ id: String, command: [String], workingDirectory: String?
    ) async throws
        -> (exitCode: Int32, stdout: String, stderr: String)
    { throw error }
    public func copy(from source: String, to destination: String) async throws { throw error }
    public func exportContainer(_ id: String, to tarPath: String) async throws { throw error }
    public func terminalCommand(for target: TerminalTarget) -> CommandLine {
        CommandLine(executable: "/bin/zsh", arguments: ["-l"])
    }

    // MARK: Images
    public func listImages() async throws -> [Image] { throw error }
    public func inspectImage(_ reference: String) async throws -> Image { throw error }
    public func pullImage(_ reference: String, platform: Platform?) -> LineStream { fail() }
    public func pushImage(_ reference: String, platform: Platform?) -> LineStream { fail() }
    public func deleteImage(_ reference: String) async throws { throw error }
    public func tagImage(_ reference: String, newReference: String) async throws { throw error }
    public func pruneImages(all: Bool) async throws { throw error }
    public func saveImages(_ references: [String], to tarPath: String, platform: Platform?) async throws { throw error }
    public func loadImages(from tarPath: String) async throws { throw error }
    public func buildImage(_ spec: BuildSpec) -> LineStream { fail() }
    public func builderStatus() async throws -> Container? { throw error }
    public func builderStart(cpus: Int?, memory: MemorySize?) async throws { throw error }
    public func builderStop() async throws { throw error }
    public func builderDelete() async throws { throw error }

    // MARK: Volumes / networks / registries
    public func listVolumes() async throws -> [Volume] { throw error }
    public func inspectVolume(_ name: String) async throws -> Volume { throw error }
    public func createVolume(name: String, size: MemorySize?, journal: String?, labels: [String: String]) async throws {
        throw error
    }
    public func deleteVolume(_ name: String) async throws { throw error }
    public func pruneVolumes() async throws { throw error }
    public func listNetworks() async throws -> [Network] { throw error }
    public func inspectNetwork(_ name: String) async throws -> Network { throw error }
    public func createNetwork(name: String, subnet: String?, subnetV6: String?, labels: [String: String]) async throws {
        throw error
    }
    public func deleteNetwork(_ name: String) async throws { throw error }
    public func pruneNetworks() async throws { throw error }
    public func listRegistries() async throws -> [RegistryLogin] { throw error }
    public func registryLogin(server: String, username: String, password: String, scheme: String?) async throws {
        throw error
    }
    public func registryLogout(server: String) async throws { throw error }

    // MARK: Machines / Kubernetes
    public func listMachines() async throws -> [Machine] { throw error }
    public func inspectMachine(_ name: String) async throws -> Machine { throw error }
    public func createMachine(_ spec: MachineSpec) -> LineStream { fail() }
    public func stopMachine(_ name: String) async throws { throw error }
    public func deleteMachine(_ name: String) async throws { throw error }
    public func setDefaultMachine(_ name: String) async throws { throw error }
    public func configureMachine(_ name: String, settings: [String: String]) async throws { throw error }
    public func machineLogs(_ name: String) async throws -> [OutputLine] { throw error }
    public func kubernetesAvailable() async -> Bool { false }
    public func listClusters() async throws -> [KubernetesCluster] { throw error }
    public func createCluster(_ spec: ClusterSpec) -> LineStream { fail() }
    public func deleteCluster(_ name: String) async throws { throw error }
    public func loadImage(
        _ reference: String, intoCluster cluster: String?, nodes: [String], platform: Platform?
    ) -> LineStream { fail() }
}
