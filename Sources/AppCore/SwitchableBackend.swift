import Foundation
import Synchronization
import ContainerKit

/// A `ContainerBackend` that forwards every call to a replaceable inner backend.
///
/// `AppModel` hands this one instance to every store, so swapping the real backend (the CLI got installed while
/// the app was running) keeps the stores — and the pollers / `.task` clients views attached to them — alive.
/// If the backend protocol grows a requirement, add a forwarding line here (as for `UnavailableBackend`).
public final class SwitchableBackend: ContainerBackend, Sendable {
    private let inner: Mutex<any ContainerBackend>

    public init(_ backend: any ContainerBackend) { inner = Mutex(backend) }

    /// The backend calls are forwarded to right now.
    public var current: any ContainerBackend { inner.withLock { $0 } }

    public func replace(with backend: any ContainerBackend) { inner.withLock { $0 = backend } }

    public var backendDescription: String { current.backendDescription }

    public func systemStatus() async throws -> SystemStatus {
        try await current.systemStatus()
    }
    public func systemStart() async throws {
        try await current.systemStart()
    }
    public func systemStop() async throws {
        try await current.systemStop()
    }
    public func systemProperties() async throws -> SystemProperties {
        try await current.systemProperties()
    }
    public func diskUsage() async throws -> DiskUsage {
        try await current.diskUsage()
    }
    public func systemLogs(lines: Int) async throws -> [OutputLine] {
        try await current.systemLogs(lines: lines)
    }
    public func listDNSDomains() async throws -> [DNSDomain] {
        try await current.listDNSDomains()
    }
    public func createDNSDomain(_ domain: String, localhostAddress: String?) async throws {
        try await current.createDNSDomain(domain, localhostAddress: localhostAddress)
    }
    public func deleteDNSDomain(_ domain: String) async throws {
        try await current.deleteDNSDomain(domain)
    }
    public func readConfigTOML() async throws -> String {
        try await current.readConfigTOML()
    }
    public func writeConfigTOML(_ text: String) async throws {
        try await current.writeConfigTOML(text)
    }
    public func listContainers(includeStopped: Bool) async throws -> [Container] {
        try await current.listContainers(includeStopped: includeStopped)
    }
    public func inspectContainer(_ id: String) async throws -> Container {
        try await current.inspectContainer(id)
    }
    public func runContainer(_ spec: RunSpec) -> LineStream {
        current.runContainer(spec)
    }
    public func createContainer(_ spec: RunSpec) async throws -> String {
        try await current.createContainer(spec)
    }
    public func startContainer(_ id: String) async throws {
        try await current.startContainer(id)
    }
    public func stopContainer(_ id: String, timeoutSeconds: Int?, signal: String?) async throws {
        try await current.stopContainer(id, timeoutSeconds: timeoutSeconds, signal: signal)
    }
    public func killContainer(_ id: String, signal: String?) async throws {
        try await current.killContainer(id, signal: signal)
    }
    public func deleteContainer(_ id: String, force: Bool) async throws {
        try await current.deleteContainer(id, force: force)
    }
    public func pruneContainers() async throws {
        try await current.pruneContainers()
    }
    public func containerLogs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> LineStream {
        current.containerLogs(id, follow: follow, boot: boot, tail: tail)
    }
    public func containerStats(ids: [String]) async throws -> [ContainerStats] {
        try await current.containerStats(ids: ids)
    }
    public func execCapture(_ id: String, command: [String], workingDirectory: String?) async throws
        -> (exitCode: Int32, stdout: String, stderr: String) {
        try await current.execCapture(id, command: command, workingDirectory: workingDirectory)
    }
    public func copy(from source: String, to destination: String) async throws {
        try await current.copy(from: source, to: destination)
    }
    public func exportContainer(_ id: String, to tarPath: String) async throws {
        try await current.exportContainer(id, to: tarPath)
    }
    public func terminalCommand(for target: TerminalTarget) -> ContainerKit.CommandLine {
        current.terminalCommand(for: target)
    }
    public func listImages() async throws -> [Image] {
        try await current.listImages()
    }
    public func inspectImage(_ reference: String) async throws -> Image {
        try await current.inspectImage(reference)
    }
    public func pullImage(_ reference: String, platform: Platform?) -> LineStream {
        current.pullImage(reference, platform: platform)
    }
    public func pushImage(_ reference: String, platform: Platform?) -> LineStream {
        current.pushImage(reference, platform: platform)
    }
    public func deleteImage(_ reference: String) async throws {
        try await current.deleteImage(reference)
    }
    public func tagImage(_ reference: String, newReference: String) async throws {
        try await current.tagImage(reference, newReference: newReference)
    }
    public func pruneImages(all: Bool) async throws {
        try await current.pruneImages(all: all)
    }
    public func saveImages(_ references: [String], to tarPath: String, platform: Platform?) async throws {
        try await current.saveImages(references, to: tarPath, platform: platform)
    }
    public func loadImages(from tarPath: String) async throws {
        try await current.loadImages(from: tarPath)
    }
    public func buildImage(_ spec: BuildSpec) -> LineStream {
        current.buildImage(spec)
    }
    public func builderStatus() async throws -> Container? {
        try await current.builderStatus()
    }
    public func builderStart(cpus: Int?, memory: MemorySize?) async throws {
        try await current.builderStart(cpus: cpus, memory: memory)
    }
    public func builderStop() async throws {
        try await current.builderStop()
    }
    public func builderDelete() async throws {
        try await current.builderDelete()
    }
    public func listVolumes() async throws -> [Volume] {
        try await current.listVolumes()
    }
    public func inspectVolume(_ name: String) async throws -> Volume {
        try await current.inspectVolume(name)
    }
    public func createVolume(name: String, size: MemorySize?, journal: String?, labels: [String: String]) async throws {
        try await current.createVolume(name: name, size: size, journal: journal, labels: labels)
    }
    public func deleteVolume(_ name: String) async throws {
        try await current.deleteVolume(name)
    }
    public func pruneVolumes() async throws {
        try await current.pruneVolumes()
    }
    public func listNetworks() async throws -> [Network] {
        try await current.listNetworks()
    }
    public func inspectNetwork(_ name: String) async throws -> Network {
        try await current.inspectNetwork(name)
    }
    public func createNetwork(name: String, subnet: String?, subnetV6: String?, labels: [String: String]) async throws {
        try await current.createNetwork(name: name, subnet: subnet, subnetV6: subnetV6, labels: labels)
    }
    public func deleteNetwork(_ name: String) async throws {
        try await current.deleteNetwork(name)
    }
    public func pruneNetworks() async throws {
        try await current.pruneNetworks()
    }
    public func listRegistries() async throws -> [RegistryLogin] {
        try await current.listRegistries()
    }
    public func registryLogin(server: String, username: String, password: String, scheme: String?) async throws {
        try await current.registryLogin(server: server, username: username, password: password, scheme: scheme)
    }
    public func registryLogout(server: String) async throws {
        try await current.registryLogout(server: server)
    }
    public func listMachines() async throws -> [Machine] {
        try await current.listMachines()
    }
    public func inspectMachine(_ name: String) async throws -> Machine {
        try await current.inspectMachine(name)
    }
    public func createMachine(_ spec: MachineSpec) -> LineStream {
        current.createMachine(spec)
    }
    public func stopMachine(_ name: String) async throws {
        try await current.stopMachine(name)
    }
    public func deleteMachine(_ name: String) async throws {
        try await current.deleteMachine(name)
    }
    public func setDefaultMachine(_ name: String) async throws {
        try await current.setDefaultMachine(name)
    }
    public func configureMachine(_ name: String, settings: [String: String]) async throws {
        try await current.configureMachine(name, settings: settings)
    }
    public func machineLogs(_ name: String) async throws -> [OutputLine] {
        try await current.machineLogs(name)
    }
    public func checkKubernetesAvailable() async throws -> Bool {
        try await current.checkKubernetesAvailable()
    }
    public func kubernetesAvailable() async -> Bool {
        await current.kubernetesAvailable()
    }
    public func listClusters() async throws -> [KubernetesCluster] {
        try await current.listClusters()
    }
    public func createCluster(_ spec: ClusterSpec) -> LineStream {
        current.createCluster(spec)
    }
    public func deleteCluster(_ name: String) async throws {
        try await current.deleteCluster(name)
    }
    public func loadImage(_ reference: String, intoCluster cluster: String?, nodes: [String], platform: Platform?) -> LineStream {
        current.loadImage(reference, intoCluster: cluster, nodes: nodes, platform: platform)
    }
}
