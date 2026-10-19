import Foundation
import Observation
import ContainerKit

/// Container machines (Apple-only Linux dev boxes).
@MainActor
@Observable
public final class MachinesStore: PollingStore {
    public private(set) var items: [Machine] = []
    public var isLoading = false
    public var loadError: BackendError?
    public var actionError: BackendError?
    /// Banner error: `actionError ?? loadError`. Setting `nil` clears both; a value becomes the `actionError`.
    public var lastError: BackendError? {
        get { actionError ?? loadError }
        set { actionError = newValue; if newValue == nil { loadError = nil } }
    }
    public var searchText = ""

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored private let tasks: TaskCenter
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.loadError { throw error }
    }
    @ObservationIgnored private let gate: PollingGate

    public init(backend: any ContainerBackend, tasks: TaskCenter, gate: PollingGate) {
        self.backend = backend
        self.tasks = tasks
        self.gate = gate
    }

    public var filtered: [Machine] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(q) || ($0.image?.reference.localizedCaseInsensitiveContains(q) ?? false) }
    }

    public var defaultMachine: Machine? { items.first(where: \.isDefault) }

    public func refresh() async {
        guard let list = await load({ try await backend.listMachines() }) else { return }
        items = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public func create(_ spec: MachineSpec) -> LongRunningTask {
        tasks.run(title: "Create machine \(spec.name)", kind: .machine, stream: backend.createMachine(spec)) { [weak self] _ in
            await self?.refresh()
        }
    }

    public func stop(_ names: [String]) async { await perform { for n in names { try await backend.stopMachine(n) } } }
    public func delete(_ names: [String]) async { await perform { for n in names { try await backend.deleteMachine(n) } } }
    public func setDefault(_ name: String) async { await perform { try await backend.setDefaultMachine(name) } }

    /// e.g. `["cpus": "8", "memory": "16g"]` — applies after the next boot.
    @discardableResult
    public func configure(_ name: String, settings: [String: String]) async -> Bool {
        await perform { try await backend.configureMachine(name, settings: settings) }
    }

    /// Full machine record (`machine ls` omits `image`/`userSetup`; `inspect` has them). `nil` on failure.
    public func inspect(_ name: String) async -> Machine? {
        try? await backend.inspectMachine(name)
    }

    public func logs(_ name: String) async -> [OutputLine] {
        (try? await backend.machineLogs(name)) ?? []
    }

    public func terminalCommand(for name: String) -> ContainerKit.CommandLine { backend.terminalCommand(for: .machine(name: name)) }
}
