import Foundation

/// Backend that drives `/usr/local/bin/container`. STUB — the "kit" workstream replaces this file with the
/// real implementation (see docs/ARCHITECTURE.md § CLIBackend). The public surface below is the contract
/// other modules may rely on: `init(executable:)`, `CLIBackend.locateExecutable()`, `backendDescription`.
public actor CLIBackend: ContainerBackend {
    public static let defaultSearchPaths = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]

    public let executable: String
    public nonisolated var backendDescription: String { "CLI (\(executable))" }

    /// - Parameter executable: explicit path; defaults to `$CONTAINER_CLI` or the first existing search path.
    public init(executable: String? = nil) throws {
        if let executable { self.executable = executable; return }
        guard let found = CLIBackend.locateExecutable() else {
            throw BackendError.cliNotInstalled(searchedPaths: CLIBackend.defaultSearchPaths)
        }
        self.executable = found
    }

    public static func locateExecutable() -> String? {
        if let env = ProcessInfo.processInfo.environment["CONTAINER_CLI"], FileManager.default.isExecutableFile(atPath: env) { return env }
        return defaultSearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func unsupported(_ name: String = #function) -> BackendError {
        .unsupported(feature: name, reason: "CLIBackend not implemented yet")
    }

    // MARK: SystemBackend
    public func systemStatus() async throws -> SystemStatus { throw unsupported() }
    public func systemStart() async throws { throw unsupported() }
    public func systemStop() async throws { throw unsupported() }
    public func systemProperties() async throws -> SystemProperties { throw unsupported() }
    public func diskUsage() async throws -> DiskUsage { throw unsupported() }
    public func systemLogs(lines: Int) async throws -> [OutputLine] { throw unsupported() }
    public func listDNSDomains() async throws -> [DNSDomain] { throw unsupported() }
    public func createDNSDomain(_ domain: String, localhostAddress: String?) async throws { throw unsupported() }
    public func deleteDNSDomain(_ domain: String) async throws { throw unsupported() }
    public func readConfigTOML() async throws -> String { throw unsupported() }
    public func writeConfigTOML(_ text: String) async throws { throw unsupported() }

    // MARK: ContainerOperations
    public func listContainers(includeStopped: Bool) async throws -> [Container] { throw unsupported() }
    public func inspectContainer(_ id: String) async throws -> Container { throw unsupported() }
    public nonisolated func runContainer(_ spec: RunSpec) -> LineStream { failing() }
    public func createContainer(_ spec: RunSpec) async throws -> String { throw unsupported() }
    public func startContainer(_ id: String) async throws { throw unsupported() }
    public func stopContainer(_ id: String, timeoutSeconds: Int?, signal: String?) async throws { throw unsupported() }
    public func killContainer(_ id: String, signal: String?) async throws { throw unsupported() }
    public func deleteContainer(_ id: String, force: Bool) async throws { throw unsupported() }
    public func pruneContainers() async throws { throw unsupported() }
    public nonisolated func containerLogs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> LineStream { failing() }
    public func containerStats(ids: [String]) async throws -> [ContainerStats] { throw unsupported() }
    public func execCapture(_ id: String, command: [String], workingDirectory: String?) async throws -> (exitCode: Int32, stdout: String, stderr: String) { throw unsupported() }
    public func copy(from source: String, to destination: String) async throws { throw unsupported() }
    public func exportContainer(_ id: String, to tarPath: String) async throws { throw unsupported() }
    public nonisolated func terminalCommand(for target: TerminalTarget) -> CommandLine {
        switch target {
        case .container(let id, let command): return CommandLine(executable: executable, arguments: ["exec", "-it", id] + command)
        case .machine(let name): return CommandLine(executable: executable, arguments: ["machine", "run", "-n", name])
        case .shell: return CommandLine(executable: "/bin/zsh", arguments: ["-l"])
        }
    }

    // MARK: ImageOperations
    public func listImages() async throws -> [Image] { throw unsupported() }
    public func inspectImage(_ reference: String) async throws -> Image { throw unsupported() }
    public nonisolated func pullImage(_ reference: String, platform: Platform?) -> LineStream { failing() }
    public nonisolated func pushImage(_ reference: String, platform: Platform?) -> LineStream { failing() }
    public func deleteImage(_ reference: String) async throws { throw unsupported() }
    public func tagImage(_ reference: String, newReference: String) async throws { throw unsupported() }
    public func pruneImages(all: Bool) async throws { throw unsupported() }
    public func saveImages(_ references: [String], to tarPath: String, platform: Platform?) async throws { throw unsupported() }
    public func loadImages(from tarPath: String) async throws { throw unsupported() }
    public nonisolated func buildImage(_ spec: BuildSpec) -> LineStream { failing() }
    public func builderStatus() async throws -> Container? { throw unsupported() }
    public func builderStart(cpus: Int?, memory: MemorySize?) async throws { throw unsupported() }
    public func builderStop() async throws { throw unsupported() }
    public func builderDelete() async throws { throw unsupported() }

    // MARK: VolumeOperations
    public func listVolumes() async throws -> [Volume] { throw unsupported() }
    public func inspectVolume(_ name: String) async throws -> Volume { throw unsupported() }
    public func createVolume(name: String, size: MemorySize?, journal: String?, labels: [String: String]) async throws { throw unsupported() }
    public func deleteVolume(_ name: String) async throws { throw unsupported() }
    public func pruneVolumes() async throws { throw unsupported() }

    // MARK: NetworkOperations
    public func listNetworks() async throws -> [Network] { throw unsupported() }
    public func inspectNetwork(_ name: String) async throws -> Network { throw unsupported() }
    public func createNetwork(name: String, subnet: String?, subnetV6: String?, labels: [String: String]) async throws { throw unsupported() }
    public func deleteNetwork(_ name: String) async throws { throw unsupported() }
    public func pruneNetworks() async throws { throw unsupported() }

    // MARK: RegistryOperations
    public func listRegistries() async throws -> [RegistryLogin] { throw unsupported() }
    public func registryLogin(server: String, username: String, password: String, scheme: String?) async throws { throw unsupported() }
    public func registryLogout(server: String) async throws { throw unsupported() }

    // MARK: MachineOperations
    public func listMachines() async throws -> [Machine] { throw unsupported() }
    public func inspectMachine(_ name: String) async throws -> Machine { throw unsupported() }
    public nonisolated func createMachine(_ spec: MachineSpec) -> LineStream { failing() }
    public func stopMachine(_ name: String) async throws { throw unsupported() }
    public func deleteMachine(_ name: String) async throws { throw unsupported() }
    public func setDefaultMachine(_ name: String) async throws { throw unsupported() }
    public func configureMachine(_ name: String, settings: [String: String]) async throws { throw unsupported() }
    public func machineLogs(_ name: String) async throws -> [OutputLine] { throw unsupported() }

    // MARK: KubernetesOperations
    public func kubernetesAvailable() async -> Bool { false }
    public func listClusters() async throws -> [KubernetesCluster] { throw unsupported() }
    public nonisolated func createCluster(_ spec: ClusterSpec) -> LineStream { failing() }
    public func deleteCluster(_ name: String) async throws { throw unsupported() }
    public nonisolated func loadImage(_ reference: String, intoCluster cluster: String?, nodes: [String], platform: Platform?) -> LineStream { failing() }

    private nonisolated func failing(_ name: String = #function) -> LineStream {
        AsyncThrowingStream { $0.finish(throwing: BackendError.unsupported(feature: name, reason: "CLIBackend not implemented yet")) }
    }
}
