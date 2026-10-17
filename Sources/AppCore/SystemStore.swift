import Foundation
import Observation
import ContainerKit

/// System-wide data: status, disk usage, merged properties, DNS domains, raw config.toml.
@MainActor
@Observable
public final class SystemStore: PollingStore {
    public private(set) var status: SystemStatus?
    public private(set) var diskUsage: DiskUsage?
    public private(set) var properties: SystemProperties?
    public private(set) var dnsDomains: [DNSDomain] = []
    public private(set) var configTOML = ""
    public var isLoading = false
    public var lastError: BackendError?

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refreshDiskUsage()
        if let error = self.lastError { throw error }
    }
    @ObservationIgnored private let gate: PollingGate

    public init(backend: any ContainerBackend, gate: PollingGate) {
        self.backend = backend
        self.gate = gate
    }

    /// Loads status, disk usage, properties and DNS domains.
    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            status = try await backend.systemStatus()
            diskUsage = try await backend.diskUsage()
            properties = try await backend.systemProperties()
            dnsDomains = try await backend.listDNSDomains()
            lastError = nil
        } catch {
            lastError = BackendError(wrapping: error)
        }
    }

    /// Cheap refresh for the status bar.
    public func refreshDiskUsage() async {
        if let df = await load({ try await backend.diskUsage() }) { diskUsage = df }
    }

    public func loadConfigTOML() async {
        if let text = await load({ try await backend.readConfigTOML() }) { configTOML = text }
    }

    /// Validates then writes config.toml. Returns false (with `lastError`) when invalid or the write fails.
    @discardableResult
    public func saveConfigTOML(_ text: String) async -> Bool {
        let issues = TOMLValidator.validate(text)
        if let first = issues.first {
            lastError = .other("config.toml line \(first.line): \(first.message)")
            return false
        }
        let ok = await perform { try await backend.writeConfigTOML(text) }
        if ok { configTOML = text }
        return ok
    }

    public func createDNSDomain(_ domain: String, localhostAddress: String? = nil) async -> Bool {
        await perform { try await backend.createDNSDomain(domain, localhostAddress: localhostAddress) }
    }

    public func deleteDNSDomain(_ domain: String) async {
        await perform { try await backend.deleteDNSDomain(domain) }
    }

    public func logs(lines: Int = 200) async -> [OutputLine] { (try? await backend.systemLogs(lines: lines)) ?? [] }
}
