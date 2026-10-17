import SwiftUI
import ContainerKit
import AppCore
import DesignSystem

/// Phase-1 containers list (features-containers replaces this in phase 2).
struct ContainersListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<Container.ID>()
    @State private var groupByProject = true
    @State private var pendingDelete: [String] = []
    @State private var showInspector = true

    private var store: ContainersStore { model.containers }
    private var selected: [Container] { store.items.filter { selection.contains($0.id) } }

    var body: some View {
        table
            .overlay { emptyState }
            .inspector(isPresented: Binding(get: { showInspector && selected.count == 1 }, set: { showInspector = $0 })) {
                if let c = selected.first { ContainerInspector(container: c, stats: store.stats[c.id], cpu: store.cpuPercent[c.id]) }
            }
            .toolbar { toolbar }
            .storeChrome(store)
            .deepLinkSelection(.containers, navigation: model.navigation, selection: $selection) { $0 }
            .confirmDestructive(title: pendingDelete.count == 1 ? "Delete container “\(pendingDelete[0])”?" : "Delete \(pendingDelete.count) containers?",
                                message: "Deletes \(pendingDelete.joined(separator: ", ")). Running containers are stopped first. "
                                    + "Anonymous volumes are kept.",
                                actionTitle: "Delete",
                                isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } })) {
                let ids = pendingDelete
                Task { await store.delete(ids, force: true); selection.subtract(ids) }
            }
    }

    private var table: some View {
        Table(of: Container.self, selection: $selection) {
            TableColumn("Name") { c in
                HStack(spacing: Spacing.s) {
                    StatusDot(c.state.statusColor, label: c.state.displayName)
                    Text(c.id).fontWeight(.medium)
                }
            }
            .width(min: 140, ideal: 180)
            TableColumn("Image") { c in Text(c.imageReference).foregroundStyle(.secondary).help(c.imageReference) }
                .width(min: 160, ideal: 240)
            TableColumn("Status") { c in Text(statusText(c)) }
                .width(min: 90, ideal: 110)
            TableColumn("CPU %") { c in
                Text(store.cpuPercent[c.id].map { Percent.format($0) } ?? emDash).monospacedDigit()
            }
            .width(min: 50, ideal: 64)
            TableColumn("Memory") { c in
                Text(store.stats[c.id].map { ByteCount.format($0.memoryUsageBytes) } ?? emDash).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Ports") { c in PortsCell(ports: c.configuration.publishedPorts) }
                .width(min: 80, ideal: 140)
            TableColumn("IP") { c in Text(c.primaryIPv4 ?? emDash).font(.monoCaption) }
                .width(min: 90, ideal: 110)
            TableColumn("Started") { c in
                Text(c.status?.startedDate.map { RelativeDate.format($0) } ?? emDash).foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        } rows: {
            if groupByProject {
                ForEach(store.groupedByProject) { group in
                    Section(group.title) {
                        ForEach(group.containers) { TableRow($0) }
                    }
                }
            } else {
                ForEach(store.filtered) { TableRow($0) }
            }
        }
        .contextMenu(forSelectionType: Container.ID.self) { ids in
            contextMenu(Array(ids))
        } primaryAction: { ids in
            selection = ids
            showInspector = true
        }
    }

    @ViewBuilder
    private func contextMenu(_ ids: [String]) -> some View {
        Button("Start") { Task { await store.start(ids) } }
        Button("Stop") { Task { await store.stop(ids) } }
        Button("Restart") { Task { await store.restart(ids) } }
        Button("Kill") { Task { await store.kill(ids) } }
        Divider()
        if ids.count == 1, let c = store.container(id: ids[0]) {
            if let ip = c.primaryIPv4 { Button("Copy IP address") { copyToPasteboard(ip) } }
            Button("Copy ID") { copyToPasteboard(c.id) }
            Divider()
        }
        Button("Delete…", role: .destructive) { pendingDelete = ids }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            let ids = Array(selection)
            ToolbarActionButton("Start", systemImage: "play.fill") { Task { await store.start(ids) } }
                .disabled(selected.isEmpty || selected.allSatisfy(\.isRunning))
            ToolbarActionButton("Stop", systemImage: "stop.fill") { Task { await store.stop(ids) } }
                .disabled(!selected.contains(where: \.isRunning))
            ToolbarActionButton("Restart", systemImage: "arrow.clockwise.circle") { Task { await store.restart(ids) } }
                .disabled(selected.isEmpty)
            ToolbarActionButton("Delete", systemImage: "trash", role: .destructive) { pendingDelete = ids }
                .disabled(selected.isEmpty)
            Menu {
                Toggle("Show stopped containers", isOn: Binding(get: { store.showStopped }, set: { store.showStopped = $0 }))
                Toggle("Hide system containers", isOn: Binding(get: { store.hideSystemManaged }, set: { store.hideSystemManaged = $0 }))
                Toggle("Group by project", isOn: $groupByProject)
            } label: {
                Label("View options", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Filter and grouping")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.filtered.isEmpty && !store.isLoading {
            if store.items.isEmpty {
                EmptyStateView(symbol: "shippingbox", title: "No containers",
                               message: "Run an image to create your first container (Images → Run).")
            } else {
                EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "No matches",
                               message: "No container matches the current search or filters.",
                               actionTitle: "Show all") {
                    store.searchText = ""
                    store.showStopped = true
                }
            }
        }
    }

    private func statusText(_ c: Container) -> String {
        if c.isRunning, let started = c.status?.startedDate { return "Running \(RelativeDate.uptime(since: started))" }
        return c.state.displayName
    }
}

/// Published ports as clickable links.
private struct PortsCell: View {
    let ports: [Container.PublishedPort]

    var body: some View {
        if ports.isEmpty {
            Text(emDash).foregroundStyle(.secondary)
        } else {
            HStack(spacing: Spacing.xs) {
                ForEach(ports, id: \.self) { p in
                    if let url = p.hostURL {
                        Link(String(p.hostPort) + ":" + String(p.containerPort), destination: url)
                            .help("Open \(url.absoluteString)")
                    } else {
                        Text(verbatim: "\(p.hostPort):\(p.containerPort)")
                    }
                }
            }
            .font(.monoCaption)
        }
    }
}

private struct ContainerInspector: View {
    let container: Container
    let stats: ContainerStats?
    let cpu: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack {
                    Text(container.id).font(.title3.bold())
                    Spacer()
                    StateBadge(container.state)
                }
                InspectorSection("Overview") {
                    KeyValueGrid([
                        ("Image", container.imageReference),
                        ("Command", container.commandLine),
                        ("Platform", container.configuration.platform.slug),
                        ("Created", RelativeDate.absolute(container.configuration.creationDate)),
                        ("Project", container.labels[AppLabel.project] ?? ""),
                    ])
                }
                InspectorSection("Network") {
                    KeyValueGrid([
                        ("IP", container.primaryIPv4 ?? ""),
                        ("Hostname", container.hostname ?? ""),
                        ("Ports", container.configuration.publishedPorts.map(\.display).joined(separator: ", ")),
                    ])
                }
                InspectorSection("Resources") {
                    KeyValueGrid([
                        ("CPUs", "\(container.configuration.resources.cpus)"),
                        ("Memory limit", ByteCount.format(container.configuration.resources.memoryInBytes)),
                        ("CPU now", cpu.map { Percent.format($0) } ?? ""),
                        ("Memory now", stats.map { ByteCount.format($0.memoryUsageBytes) } ?? ""),
                        ("Processes", stats.map { "\($0.numProcesses)" } ?? ""),
                    ])
                }
            }
            .padding(Spacing.l)
        }
    }
}
