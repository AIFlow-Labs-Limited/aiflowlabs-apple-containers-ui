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
    public var loadError: BackendError?
    public var actionError: BackendError?
    /// Banner error: `actionError ?? loadError`. Setting `nil` clears both; a value becomes the `actionError`.
    public var lastError: BackendError? {
        get { actionError ?? loadError }
        set { actionError = newValue; if newValue == nil { loadError = nil } }
    }

    @ObservationIgnored private let backend: any ContainerBackend
    /// Status-bar lane: disk usage every 10 s (it shells out to `system df`, so not at the 2 s list rate).
    public static let diskUsageInterval: Duration = .seconds(10)
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate, interval: Self.diskUsageInterval) { [weak self] in
        guard let self else { return }
        await self.refreshDiskUsage()
        if let error = self.loadError { throw error }
    }
    @ObservationIgnored private let gate: PollingGate

    public init(backend: any ContainerBackend, gate: PollingGate) {
        self.backend = backend
        self.gate = gate
    }

    /// Loads status, disk usage, properties and DNS domains.
    public func refresh() async {
        let result = await load { () async throws -> (SystemStatus, DiskUsage, SystemProperties, [DNSDomain]) in
            (try await backend.systemStatus(), try await backend.diskUsage(), try await backend.systemProperties(),
             try await backend.listDNSDomains())
        }
        guard let (status, diskUsage, properties, dnsDomains) = result else { return }
        self.status = status
        self.diskUsage = diskUsage
        self.properties = properties
        self.dnsDomains = dnsDomains
    }

    /// Cheap refresh for the status bar.
    public func refreshDiskUsage() async {
        if let df = await load({ try await backend.diskUsage() }) { diskUsage = df }
    }

    public func loadConfigTOML() async {
        if let text = await load({ try await backend.readConfigTOML() }) { configTOML = text }
    }

    /// Validates then writes config.toml. Returns false (with `actionError`) when invalid or the write fails.
    @discardableResult
    public func saveConfigTOML(_ text: String) async -> Bool {
        let issues = TOMLValidator.validate(text)
        if let first = issues.first {
            actionError = .other("config.toml line \(first.line): \(first.message)")
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
