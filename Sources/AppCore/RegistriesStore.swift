import Foundation
import Observation
import ContainerKit

/// Registry logins. Passwords are handed to the backend (which pipes them via stdin) and never stored here.
@MainActor
@Observable
public final class RegistriesStore: PollingStore {
    public private(set) var items: [RegistryLogin] = []
    public var isLoading = false
    public var lastError: BackendError?
    public var searchText = ""

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.lastError { throw error }
    }
    @ObservationIgnored private let gate: PollingGate

    public init(backend: any ContainerBackend, gate: PollingGate) {
        self.backend = backend
        self.gate = gate
    }

    public var filtered: [RegistryLogin] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.server.localizedCaseInsensitiveContains(q) || ($0.username?.localizedCaseInsensitiveContains(q) ?? false) }
    }

    public func refresh() async {
        guard let list = await load({ try await backend.listRegistries() }) else { return }
        items = list.sorted { $0.server < $1.server }
    }

    public func login(server: String, username: String, password: String, scheme: String? = nil) async -> Bool {
        await perform { try await backend.registryLogin(server: server, username: username, password: password, scheme: scheme) }
    }

    public func logout(_ servers: [String]) async {
        await perform { for s in servers { try await backend.registryLogout(server: s) } }
    }
}
