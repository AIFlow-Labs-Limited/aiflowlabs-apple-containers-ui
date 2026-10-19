import ContainerKit
import ContainerKitMock
import Foundation

@testable import AppCore

@MainActor
enum TestSupport {
    static func defaults() -> UserDefaults {
        let name = "AppCoreTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    static func historyURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "cd-tests-\(UUID().uuidString)").appending(
            path: "builds.json")
    }

    static func model(_ backend: any ContainerBackend = MockBackend()) -> AppModel {
        AppModel(
            backend: backend, settings: SettingsStore(defaults: defaults()), buildsHistoryURL: historyURL(),
            observeAppActivation: false)
    }
}

/// A backend whose every call fails with a fixed error, for error-path tests.
struct FailingBackend: ContainerBackend {
    let wrapped = UnavailableBackend(searchedPaths: [])
    let error: BackendError
    var backendDescription: String { "Failing" }

    func systemStatus() async throws -> SystemStatus { throw error }
    func systemStart() async throws { throw error }
    func systemStop() async throws { throw error }
    func systemProperties() async throws -> SystemProperties { throw error }
    func diskUsage() async throws -> DiskUsage { throw error }
    func systemLogs(lines: Int) async throws -> [OutputLine] { throw error }
    func listDNSDomains() async throws -> [DNSDomain] { throw error }
    func createDNSDomain(_ domain: String, localhostAddress: String?) async throws { throw error }
    func deleteDNSDomain(_ domain: String) async throws { throw error }
    func readConfigTOML() async throws -> String { throw error }
    func writeConfigTOML(_ text: String) async throws { throw error }
    func listContainers(includeStopped: Bool) async throws -> [Container] { throw error }
    func inspectContainer(_ id: String) async throws -> Container { throw error }
    func runContainer(_ spec: RunSpec) -> LineStream { fail() }
    func createContainer(_ spec: RunSpec) async throws -> String { throw error }
    func startContainer(_ id: String) async throws { throw error }
    func stopContainer(_ id: String, timeoutSeconds: Int?, signal: String?) async throws { throw error }
    func killContainer(_ id: String, signal: String?) async throws { throw error }
    func deleteContainer(_ id: String, force: Bool) async throws { throw error }
    func pruneContainers() async throws { throw error }
    func containerLogs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> LineStream { fail() }
    func containerStats(ids: [String]) async throws -> [ContainerStats] { throw error }
    func execCapture(
        _ id: String, command: [String], workingDirectory: String?
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) { throw error }
    func copy(from source: String, to destination: String) async throws { throw error }
    func exportContainer(_ id: String, to tarPath: String) async throws { throw error }
    func terminalCommand(for target: TerminalTarget) -> ContainerKit.CommandLine {
        wrapped.terminalCommand(for: target)
    }
    func listImages() async throws -> [Image] { throw error }
    func inspectImage(_ reference: String) async throws -> Image { throw error }
    func pullImage(_ reference: String, platform: Platform?) -> LineStream { fail() }
    func pushImage(_ reference: String, platform: Platform?) -> LineStream { fail() }
    func deleteImage(_ reference: String) async throws { throw error }
    func tagImage(_ reference: String, newReference: String) async throws { throw error }
    func pruneImages(all: Bool) async throws { throw error }
    func saveImages(_ references: [String], to tarPath: String, platform: Platform?) async throws { throw error }
    func loadImages(from tarPath: String) async throws { throw error }
    func buildImage(_ spec: BuildSpec) -> LineStream { fail() }
    func builderStatus() async throws -> Container? { throw error }
    func builderStart(cpus: Int?, memory: MemorySize?) async throws { throw error }
    func builderStop() async throws { throw error }
    func builderDelete() async throws { throw error }
    func listVolumes() async throws -> [Volume] { throw error }
    func inspectVolume(_ name: String) async throws -> Volume { throw error }
    func createVolume(name: String, size: MemorySize?, journal: String?, labels: [String: String]) async throws {
        throw error
    }
    func deleteVolume(_ name: String) async throws { throw error }
    func pruneVolumes() async throws { throw error }
    func listNetworks() async throws -> [Network] { throw error }
    func inspectNetwork(_ name: String) async throws -> Network { throw error }
    func createNetwork(name: String, subnet: String?, subnetV6: String?, labels: [String: String]) async throws {
        throw error
    }
    func deleteNetwork(_ name: String) async throws { throw error }
    func pruneNetworks() async throws { throw error }
    func listRegistries() async throws -> [RegistryLogin] { throw error }
    func registryLogin(server: String, username: String, password: String, scheme: String?) async throws { throw error }
    func registryLogout(server: String) async throws { throw error }
    func listMachines() async throws -> [Machine] { throw error }
    func inspectMachine(_ name: String) async throws -> Machine { throw error }
    func createMachine(_ spec: MachineSpec) -> LineStream { fail() }
    func stopMachine(_ name: String) async throws { throw error }
    func deleteMachine(_ name: String) async throws { throw error }
    func setDefaultMachine(_ name: String) async throws { throw error }
    func configureMachine(_ name: String, settings: [String: String]) async throws { throw error }
    func machineLogs(_ name: String) async throws -> [OutputLine] { throw error }
    func kubernetesAvailable() async -> Bool { true }
    func listClusters() async throws -> [KubernetesCluster] { throw error }
    func createCluster(_ spec: ClusterSpec) -> LineStream { fail() }
    func deleteCluster(_ name: String) async throws { throw error }
    func loadImage(
        _ reference: String, intoCluster cluster: String?, nodes: [String], platform: Platform?
    ) -> LineStream { fail() }

    private func fail() -> LineStream { let e = error; return AsyncThrowingStream { $0.finish(throwing: e) } }
}
