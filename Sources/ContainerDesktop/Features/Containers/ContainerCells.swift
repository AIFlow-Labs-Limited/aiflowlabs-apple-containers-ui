import SwiftUI
import AppKit
import ContainerKit
import AppCore
import DesignSystem

/// Status dot + name (project rows get a stack icon).
struct ContainerNameCell: View {
    let row: ContainerRow

    var body: some View {
        HStack(spacing: Spacing.s) {
            if row.isProject {
                SwiftUI.Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(row.state == .running ? Color.statusRunning : Color.statusStopped)
                    .accessibilityHidden(true)
            } else {
                StatusDot(row.state.statusColor, label: row.state.displayName)
            }
            Text(row.name)
                .fontWeight(row.isProject ? .semibold : .medium)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.isProject ? "Project \(row.name), \(row.statusText)" : "\(row.name), \(row.state.displayName)")
    }
}

/// "38 MB / 512 MB" with a thin usage bar underneath.
struct MemoryCell: View {
    let row: ContainerRow

    var body: some View {
        if row.state == .running && row.memory > 0 {
            let fraction = row.memoryLimit > 0 ? min(1, Double(row.memory) / Double(row.memoryLimit)) : 0
            VStack(alignment: .leading, spacing: 2) {
                Text("\(ByteCount.format(row.memory)) / \(ByteCount.format(row.memoryLimit))")
                    .monospacedDigit()
                    .lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(fraction > 0.9 ? Color.statusError : (fraction > 0.75 ? .statusWarning : .accentColor))
                            .frame(width: max(2, geo.size.width * fraction))
                    }
                }
                .frame(height: 3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Memory \(ByteCount.format(row.memory)) of \(ByteCount.format(row.memoryLimit))")
        } else {
            Text(emDash).foregroundStyle(.secondary)
        }
    }
}

/// Published ports as chips: click opens `http://127.0.0.1:<port>`, ⌥-click copies the URL.
struct PortChips: View {
    let ports: [Container.PublishedPort]
    var limit = 3

    var body: some View {
        if ports.isEmpty {
            Text(emDash).foregroundStyle(.secondary)
        } else {
            HStack(spacing: Spacing.xs) {
                ForEach(ports.prefix(limit), id: \.self) { PortChip(port: $0) }
                if ports.count > limit {
                    Text("+\(ports.count - limit)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(ports.dropFirst(limit).map(\.display).joined(separator: "\n"))
                }
            }
        }
    }
}

struct PortChip: View {
    let port: Container.PublishedPort
    @State private var copied = false

    var body: some View {
        Button(action: activate) {
            HStack(spacing: 2) {
                Text(copied ? "Copied" : "\(String(port.hostPort)):\(String(port.containerPort))")
                if !copied {
                    SwiftUI.Image(systemName: "arrow.up.right.square").font(.caption2).accessibilityHidden(true)
                }
            }
            .font(.monoCaption)
            .padding(.horizontal, Spacing.xs + 1)
            .padding(.vertical, 1)
            .foregroundStyle(.tint)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .help("Open \(port.hostURL?.absoluteString ?? port.display) — ⌥-click to copy")
        .accessibilityLabel("Port \(port.hostPort) to \(port.containerPort)")
        .accessibilityHint("Opens in the browser. Option-click copies the address.")
        .contextMenu {
            if let url = port.hostURL {
                Button("Open \(url.absoluteString)") { NSWorkspace.shared.open(url) }
                Button("Copy URL") { copyToPasteboard(url.absoluteString) }
            }
            Button("Copy Mapping") { copyToPasteboard(port.display) }
        }
    }

    private func activate() {
        guard let url = port.hostURL else { return }
        if NSEvent.modifierFlags.contains(.option) {
            copyToPasteboard(url.absoluteString)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                copied = false
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

/// ▶/■ toggle + ⋯ menu (rows) or Start all / Stop all / Delete all (project headers).
struct ContainerActionsCell: View {
    let row: ContainerRow
    let actions: ContainerActions

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if row.isProject {
                let anyStopped = row.members.contains { !$0.isRunning }
                let anyRunning = row.members.contains(where: \.isRunning)
                iconButton(anyStopped ? "Start all in \(row.name)" : "Stop all in \(row.name)",
                           symbol: anyStopped ? "play.fill" : "stop.fill") {
                    anyStopped ? actions.start(row.memberIDs) : actions.stop(row.memberIDs)
                }
                Menu {
                    Button("Start All", systemImage: "play.fill") { actions.start(row.memberIDs) }.disabled(!anyStopped)
                    Button("Stop All", systemImage: "stop.fill") { actions.stop(row.memberIDs) }.disabled(!anyRunning)
                    Button("Restart All", systemImage: "arrow.clockwise") { actions.restart(row.memberIDs) }
                    Divider()
                    Button("Delete All…", systemImage: "trash", role: .destructive) { actions.requestDelete(row.memberIDs) }
                } label: {
                    SwiftUI.Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Project actions")
                .accessibilityLabel("Actions for project \(row.name)")
            } else if let c = row.container {
                iconButton(c.isRunning ? "Stop \(c.id)" : "Start \(c.id)", symbol: c.isRunning ? "stop.fill" : "play.fill") {
                    actions.toggle(c)
                }
                Menu {
                    ContainerMenuItems(ids: [c.id], actions: actions)
                } label: {
                    SwiftUI.Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions for \(c.id)")
            }
        }
    }

    private func iconButton(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { SwiftUI.Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }
}
