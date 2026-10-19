import Foundation
import Observation
import AppKit
import ContainerKit

/// Root of the app's state: backend, engine state, child stores, tasks, toasts, navigation, settings.
/// Injected via `.environment(model)` and `\.appModel`; never a singleton.
@MainActor
@Observable
public final class AppModel {
    public struct ErrorRecord: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let error: BackendError
    }

    public private(set) var backend: any ContainerBackend
    public private(set) var engine: EngineState = .checking
    public private(set) var recentErrors: [ErrorRecord] = []
    /// Set while an engine start/stop is in flight.
    public private(set) var engineBusy = false

    public let settings: SettingsStore
    public let gate: PollingGate
    public let taskCenter: TaskCenter
    public let toasts = ToastCenter()
    public let navigation = NavigationModel()
    public let palette = CommandPalette()
    /// "Run" hand-off from Images/Builds to the Containers run sheet.
    public let runRequests = RunRequests()

    public private(set) var containers: ContainersStore
    public private(set) var images: ImagesStore
    public private(set) var volumes: VolumesStore
    public private(set) var networks: NetworksStore
    public private(set) var builds: BuildsStore
    public private(set) var machines: MachinesStore
    public private(set) var clusters: ClustersStore
    public private(set) var registries: RegistriesStore
    public private(set) var system: SystemStore

    @ObservationIgnored private let buildsHistoryURL: URL
    @ObservationIgnored private let notifier = SystemNotifier()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored public private(set) lazy var enginePoller = Poller(gate: gate, requiresEngine: false) { [weak self] in
        await self?.refreshEngine()
    }
    @ObservationIgnored private var didBootstrap = false

    public init(backend: any ContainerBackend, settings: SettingsStore = SettingsStore(),
                buildsHistoryURL: URL = BuildsStore.defaultHistoryURL, observeAppActivation: Bool = true) {
        let gate = PollingGate(interval: .seconds(settings.pollingInterval))
        let tasks = TaskCenter()
        self.backend = backend
        self.settings = settings
        self.gate = gate
        self.taskCenter = tasks
        self.buildsHistoryURL = buildsHistoryURL
        (containers, images, volumes, networks, builds, machines, clusters, registries, system) =
            Self.makeStores(backend: backend, gate: gate, tasks: tasks, historyURL: buildsHistoryURL)
        configureStores()
        wireCallbacks()
        if observeAppActivation { observeActivation() }
        if let unavailable = backend as? UnavailableBackend { engine = .notInstalled(searchedPaths: unavailable.searchedPaths) }
    }

    /// Chooses the backend from `CONTAINER_DESKTOP_BACKEND`. `mock` is a factory because AppCore does not link
    /// ContainerKitMock; the app passes `{ MockBackend() }`.
    public static func make(selection: BackendSelection = .fromEnvironment, mock: () -> any ContainerBackend,
                            settings: SettingsStore = SettingsStore()) -> AppModel {
        AppModel(backend: makeBackend(selection: selection, mock: mock), settings: settings)
    }

    static func makeBackend(selection: BackendSelection, mock: () -> any ContainerBackend) -> any ContainerBackend {
        switch selection {
        case .mock:
            return mock()
        case .cli:
            do { return try CLIBackend() } catch let BackendError.cliNotInstalled(paths) {
                return UnavailableBackend(searchedPaths: paths)
            } catch {
                return UnavailableBackend(searchedPaths: CLIBackend.defaultSearchPaths)
            }
        }
    }

    // MARK: Engine

    /// First-appearance work: probe the engine, start polling, optionally start the engine.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await refreshEngine()
        if case .stopped = engine, settings.startEngineOnLaunch { await startEngine() }
        enginePoller.start(interval: .seconds(5))
    }

    /// Probes `system status` and maps the result to `EngineState`.
    public func refreshEngine() async {
        if backend is UnavailableBackend {
            // "Check again": the CLI may have been installed since launch.
            guard CLIBackend.locateExecutable() != nil, let cli = try? CLIBackend() else {
                setEngine(.notInstalled(searchedPaths: CLIBackend.defaultSearchPaths))
                return
            }
            replaceBackend(cli)
        }
        guard !engineBusy else { return }
        do {
            let status = try await backend.systemStatus()
            setEngine(status.isRunning ? .running(status) : .stopped)
        } catch {
            let wrapped = BackendError(wrapping: error)
            switch wrapped {
            case .systemNotRunning: setEngine(.stopped)
            case .cliNotInstalled(let paths): setEngine(.notInstalled(searchedPaths: paths))
            default:
                if engine != .error(wrapped) { record(wrapped) }
                setEngine(.error(wrapped))
            }
        }
    }

    /// `container system start`, then waits (≤ 60 s) for the apiserver to report running.
    public func startEngine() async {
        guard !engineBusy else { return }
        engineBusy = true
        setEngine(.starting)
        do {
            try await backend.systemStart()
            for _ in 0..<60 {
                if let s = try? await backend.systemStatus(), s.isRunning { break }
                try await Task.sleep(for: .seconds(1))
            }
            engineBusy = false
            await refreshEngine()
            if engine.isRunning { toasts.success("Container system started") }
        } catch {
            engineBusy = false
            let wrapped = BackendError(wrapping: error)
            record(wrapped)
            setEngine(.error(wrapped))
        }
    }

    public func stopEngine() async {
        guard !engineBusy else { return }
        engineBusy = true
        do {
            try await backend.systemStop()
            engineBusy = false
            await refreshEngine()
            toasts.info("Container system stopped")
        } catch {
            engineBusy = false
            let wrapped = BackendError(wrapping: error)
            record(wrapped)
            toasts.error("Could not stop the container system", message: wrapped.errorDescription)
            await refreshEngine()
        }
    }

    private func setEngine(_ state: EngineState) {
        let wasRunning = engine.isRunning
        if engine != state { engine = state }
        gate.engineRunning = state.isRunning
        // Engine came up (launch, Start button, or started from the CLI): load every section once.
        if state.isRunning && !wasRunning { Task { await refreshAll() } }
    }

    // MARK: Refresh helpers

    /// Refreshes the store backing `section`.
    public func refresh(_ section: SidebarSection) async {
        switch section {
        case .containers: await containers.refresh(); await containers.refreshStats()
        case .images: await images.refresh()
        case .volumes: await volumes.refresh()
        case .networks: await networks.refresh()
        case .builds: await builds.refresh()
        case .machines: await machines.refresh()
        case .kubernetes: await clusters.refresh()
        case .registries: await registries.refresh()
        }
    }

    public func refreshAll() async {
        await containers.refresh()
        await images.refresh()
        await volumes.refresh()
        await networks.refresh()
        await machines.refresh()
        await clusters.refresh()
        await registries.refresh()
        await system.refresh()
    }

    /// Store `lastError` for a section (for banners).
    public func lastError(for section: SidebarSection) -> BackendError? {
        switch section {
        case .containers: containers.lastError
        case .images: images.lastError
        case .volumes: volumes.lastError
        case .networks: networks.lastError
        case .builds: builds.lastError
        case .machines: machines.lastError
        case .kubernetes: clusters.lastError
        case .registries: registries.lastError
        }
    }

    /// Item count for the sidebar badge.
    public func count(for section: SidebarSection) -> Int {
        switch section {
        case .containers: containers.visibleCount
        case .images: images.items.count
        case .volumes: volumes.items.count
        case .networks: networks.items.count
        case .builds: builds.history.count
        case .machines: machines.items.count
        case .kubernetes: clusters.items.count
        case .registries: registries.items.count
        }
    }

    public func record(_ error: BackendError) {
        recentErrors.insert(ErrorRecord(date: .now, error: error), at: 0)
        if recentErrors.count > 20 { recentErrors.removeLast() }
    }

    // MARK: Wiring

    private func replaceBackend(_ newBackend: any ContainerBackend) {
        backend = newBackend
        rebuildStores()
    }

    private func rebuildStores() {
        (containers, images, volumes, networks, builds, machines, clusters, registries, system) =
            Self.makeStores(backend: backend, gate: gate, tasks: taskCenter, historyURL: buildsHistoryURL)
        configureStores()
    }

    private func configureStores() {
        containers.showStopped = settings.showStoppedContainers
        containers.hideSystemManaged = settings.hideSystemContainers
        containers.onUnexpectedExit = { [weak self] c in
            guard let self else { return }
            self.toasts.error("\(c.id) exited", message: c.imageReference)
            if self.settings.notificationsEnabled {
                Task { await self.notifier.post(title: "Container exited", body: "\(c.id) (\(c.imageReference)) stopped unexpectedly.") }
            }
        }
    }

    private func wireCallbacks() {
        settings.onPollingIntervalChange = { [weak self] seconds in self?.gate.interval = .seconds(seconds) }
        taskCenter.onFinish = { [weak self] task in
            guard let self else { return }
            switch task.state {
            case .succeeded: self.toasts.success(task.title, message: "Finished in \(Int(task.duration))s")
            case .failed(let e): self.record(e); self.toasts.error(task.title, message: e.errorDescription)
            case .cancelled: self.toasts.info(task.title, message: "Cancelled")
            case .running: break
            }
            if self.settings.notificationsEnabled, task.state != .cancelled {
                let body = task.state == .succeeded ? "Finished successfully." : "Failed."
                Task { await self.notifier.post(title: task.title, body: body) }
            }
        }
    }

    private func observeActivation() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gate.appActive = false }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.gate.appActive = true }
        })
    }

    private typealias Stores = (ContainersStore, ImagesStore, VolumesStore, NetworksStore, BuildsStore,
                                MachinesStore, ClustersStore, RegistriesStore, SystemStore)

    private static func makeStores(backend: any ContainerBackend, gate: PollingGate, tasks: TaskCenter, historyURL: URL) -> Stores {
        let containers = ContainersStore(backend: backend, gate: gate)
        return (containers,
                ImagesStore(backend: backend, containers: containers, tasks: tasks, gate: gate),
                VolumesStore(backend: backend, containers: containers, gate: gate),
                NetworksStore(backend: backend, containers: containers, gate: gate),
                BuildsStore(backend: backend, tasks: tasks, gate: gate, historyURL: historyURL),
                MachinesStore(backend: backend, tasks: tasks, gate: gate),
                ClustersStore(backend: backend, tasks: tasks, gate: gate),
                RegistriesStore(backend: backend, gate: gate),
                SystemStore(backend: backend, gate: gate))
    }
}
