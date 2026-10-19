import AppCore
import AppKit
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// Detail pane for one container: header with lifecycle buttons, tab bar, and the selected tab
/// (persisted per container in `ContainersUIState`).
struct ContainerDetailView: View {
    let container: Container
    @Bindable var ui: ContainersUIState
    let actions: ContainerActions

    private var tab: Binding<ContainerDetailTab> {
        Binding(get: { ui.tab(for: container.id) }, set: { ui.setTab($0, for: container.id) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("Tab", selection: tab) {
                ForEach(ContainerDetailTab.allCases) { t in Text(t.title).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 640)
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.s)
            .accessibilityLabel("Detail tab")
            Divider()
            content
                .id(container.id)  // fresh tab state (log stream, sampler, terminal) per container
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.s) {
                    Text(container.id).font(.headline)
                    // Ticks every second so the uptime matches the table instead of freezing between polls.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        StateBadge(
                            container.state,
                            detail: container.status?.startedDate.flatMap {
                                container.isRunning ? RelativeDate.uptime(since: $0, now: context.date) : nil
                            })
                    }
                }
                Text(container.imageReference)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: Spacing.s)
            HStack(spacing: Spacing.xs) {
                if container.isRunning {
                    iconButton("Stop", "stop.fill") { actions.stop([container.id]) }
                } else {
                    iconButton("Start", "play.fill") { actions.start([container.id]) }
                }
                iconButton("Restart", "arrow.clockwise") { actions.restart([container.id]) }
                iconButton("Delete", "trash") { actions.requestDelete([container.id]) }
                Menu {
                    ContainerMenuItems(ids: [container.id], actions: actions)
                } label: {
                    SwiftUI.Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
                iconButton("Hide details", "chevron.down") { ui.showDetail = false }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    private var content: some View {
        DetailTabContent(
            container: container, tab: tab.wrappedValue, actions: actions,
            statsHistory: actions.model.containers.statsHistory)
    }

    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { SwiftUI.Image(systemName: symbol) }
            .help(title)
            .accessibilityLabel(title)
    }
}

/// The selected tab's content. The Terminal tab stays mounted (hidden) once opened so switching tabs keeps its
/// `container exec` session alive; it is reset per container by the parent's `.id(container.id)`.
private struct DetailTabContent: View {
    let container: Container
    let tab: ContainerDetailTab
    let actions: ContainerActions
    let statsHistory: ContainerStatsHistory
    @State private var terminalMounted = false

    var body: some View {
        ZStack {
            if terminalMounted || tab == .terminal {
                ContainerTerminalTab(container: container, actions: actions)
                    .opacity(tab == .terminal ? 1 : 0)
                    .allowsHitTesting(tab == .terminal)
                    .accessibilityHidden(tab != .terminal)
            }
            if tab != .terminal {
                other.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
            }
        }
        .onChange(of: tab, initial: true) { old, new in
            if new == .terminal { terminalMounted = true }
            // Keystrokes must not keep going to the hidden shell.
            if old == .terminal, new != .terminal { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
    }

    @ViewBuilder
    private var other: some View {
        switch tab {
        case .logs: ContainerLogsTab(container: container)
        case .inspect: ContainerInspectTab(container: container)
        case .terminal: EmptyView()
        case .stats: ContainerStatsTab(container: container, history: statsHistory)
        case .mounts: ContainerMountsTab(container: container)
        case .ports: ContainerPortsTab(container: container, actions: actions)
        case .environment: ContainerEnvironmentTab(container: container)
        }
    }
}

#Preview("Container detail") {
    @Previewable @State var ui = ContainersUIState()
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    let container = Container(
        id: "web",
        configuration: .init(
            id: "web",
            image: ImageReference(
                reference: "docker.io/library/nginx:alpine",
                descriptor: Descriptor(digest: "sha256:ab", mediaType: "x", size: 1)),
            creationDate: .now,
            initProcess: .init(
                executable: "nginx", arguments: ["-g", "daemon off;"],
                environment: ["PATH=/usr/bin", "API_TOKEN=s3cret"]),
            publishedPorts: [.init(hostPort: 8080, containerPort: 80)]),
        status: .init(
            state: .running, startedDate: .now.addingTimeInterval(-7200),
            networks: [.init(ipv4Address: "192.168.64.3/24")]))
    ContainerDetailView(container: container, ui: ui, actions: ContainerActions(model: model, ui: ui))
        .appModelEnvironment(model)
        .frame(width: 900, height: 480)
}
