import SwiftUI
import AppCore
import DesignSystem

/// Main window: sidebar · section content (gated on engine state) · terminal panel · status bar.
struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @FocusState private var searchFocused: Bool
    @State private var confirmingEngineStop = false

    private var section: SidebarSection { model.navigation.section ?? .containers }

    var body: some View {
        @Bindable var nav = model.navigation
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            VStack(spacing: 0) {
                EngineGateView {
                    SectionContentView(section: section)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if nav.isTerminalOpen {
                    TerminalPanel()
                        .transition(.move(edge: .bottom))
                }
                StatusBar()
            }
            .navigationTitle(section.title)
        }
        .searchable(text: searchBinding, placement: .toolbar, prompt: "Search \(section.title.lowercased())")
        .searchFocused($searchFocused)
        .toolbar { toolbarContent }
        .sheet(isPresented: $nav.isPaletteOpen) {
            CommandPaletteView {
                // Present after the palette sheet has gone so the alert attaches to the window.
                Task { try? await Task.sleep(for: .milliseconds(250)); confirmingEngineStop = true }
            }
        }
        .confirmDestructive(title: EngineStopConfirmation.title, message: EngineStopConfirmation.message(for: model),
                            actionTitle: EngineStopConfirmation.actionTitle, isPresented: $confirmingEngineStop) {
            Task { await model.stopEngine() }
        }
        .sheet(isPresented: $nav.isCleanupOpen) { CleanupSheet() }
        .overlay(alignment: .bottomTrailing) { ToastOverlay().padding(.bottom, 40).padding(.trailing, Spacing.l) }
        .background {
            // ⌘F focuses the toolbar search field.
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .frame(minWidth: 1100, minHeight: 700)
        .task {
            await model.bootstrap()
            model.containers.startPolling()
            model.system.startPolling()
            #if DEBUG
            await DebugLaunchActions.run(model: model, openWindow: openWindow, openSettings: openSettings)
            #endif
        }
        .onDisappear {
            // Balances the `startPolling()` above (pollers are reference counted). The menu bar keeps its data fresh
            // through AppModel's background client on the containers poller, which this does not remove.
            model.containers.stopPolling()
            model.system.stopPolling()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.refresh(section) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .help("Refresh (⌘R)")
            .disabled(!model.engine.isRunning)

            Button {
                withAnimation { model.navigation.isTerminalOpen.toggle() }
            } label: {
                Label("Terminal", systemImage: "terminal")
            }
            .help("Toggle terminal (⌘T)")

            Button { model.navigation.isPaletteOpen = true } label: {
                Label("Command Palette", systemImage: "command")
            }
            .help("Command palette (⌘K)")

            Button { openWindow(id: SceneID.activity) } label: {
                Label("Activity", systemImage: "list.bullet.rectangle")
                    .overlay(alignment: .topTrailing) { ActivityBadge(count: model.taskCenter.activeCount) }
            }
            .help(model.taskCenter.activeCount > 0 ? "Activity — \(model.taskCenter.activeCount) running" : "Activity")
            .accessibilityLabel("Activity, \(model.taskCenter.activeCount) running")

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .help("Settings (⌘,)")
        }
    }

    private var searchBinding: Binding<String> {
        let m = model
        switch section {
        case .containers: return Binding(get: { m.containers.searchText }, set: { m.containers.searchText = $0 })
        case .images: return Binding(get: { m.images.searchText }, set: { m.images.searchText = $0 })
        case .volumes: return Binding(get: { m.volumes.searchText }, set: { m.volumes.searchText = $0 })
        case .networks: return Binding(get: { m.networks.searchText }, set: { m.networks.searchText = $0 })
        case .builds: return Binding(get: { m.builds.searchText }, set: { m.builds.searchText = $0 })
        case .machines: return Binding(get: { m.machines.searchText }, set: { m.machines.searchText = $0 })
        case .kubernetes: return Binding(get: { m.clusters.searchText }, set: { m.clusters.searchText = $0 })
        case .registries: return Binding(get: { m.registries.searchText }, set: { m.registries.searchText = $0 })
        }
    }
}

/// Small count bubble for the Activity toolbar button.
private struct ActivityBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 14, minHeight: 14)
                .background(Color.accentColor, in: Capsule())
                .offset(x: 8, y: -6)
                .accessibilityHidden(true)
        }
    }
}

/// Routes the selected sidebar section to its list view.
struct SectionContentView: View {
    let section: SidebarSection

    var body: some View {
        switch section {
        case .containers: ContainersListView()
        case .images: ImagesListView()
        case .volumes: VolumesListView()
        case .networks: NetworksListView()
        case .builds: BuildsListView()
        case .machines: MachinesListView()
        case .kubernetes: KubernetesListView()
        case .registries: RegistriesListView()
        }
    }
}

extension EngineState {
    /// Status color for dots in the sidebar footer, status bar and menu bar.
    var color: Color {
        switch self {
        case .running: return .statusRunning
        case .stopped, .checking: return .statusStopped
        case .starting: return .statusWarning
        case .notInstalled, .error: return .statusError
        }
    }
}
