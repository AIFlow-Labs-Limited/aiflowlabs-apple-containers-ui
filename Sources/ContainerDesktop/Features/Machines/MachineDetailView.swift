import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

enum MachineDetailTab: String, CaseIterable, Identifiable {
    case overview = "Overview", terminal = "Terminal", logs = "Logs"
    var id: String { rawValue }
}

/// Inspector for one machine: key facts + explainer, an embedded terminal (`machine run`), and boot logs.
struct MachineDetailView: View {
    let machine: Machine
    @Binding var tab: MachineDetailTab
    let onResize: () -> Void
    let onStop: () -> Void
    /// The terminal is created the first time its tab is shown and then kept alive (hidden) while other tabs are
    /// shown, so switching to Overview or Logs doesn't kill the shell session.
    @State private var terminalStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding([.horizontal, .top], Spacing.l)
            Picker("View", selection: $tab) {
                ForEach(MachineDetailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Spacing.l)
            Divider()
            ZStack {
                if terminalStarted {
                    MachineTerminalTab(machine: machine)
                        .id(machine.name)
                        .opacity(tab == .terminal ? 1 : 0)
                        .allowsHitTesting(tab == .terminal)
                        .accessibilityHidden(tab != .terminal)
                }
                switch tab {
                case .overview: MachineOverview(machine: machine, onResize: onResize).background(.background)
                case .terminal: EmptyView()
                case .logs: MachineLogsTab(name: machine.name).id(machine.name).background(.background)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .onChange(of: tab, initial: true) { if tab == .terminal { terminalStarted = true } }
        // Another machine selected: its terminal starts fresh, and only once its tab is opened.
        .onChange(of: machine.name) { terminalStarted = tab == .terminal }
    }

    private var header: some View {
        HStack(spacing: Spacing.s) {
            StatusDot(machine.isRunning ? .statusRunning : .statusStopped, size: 10, label: machine.status.rawValue)
            Text(machine.name).font(.title3.bold()).textSelection(.enabled)
            if machine.isDefault { TagBadge("default", tint: .accentColor) }
            Spacer()
            Button("Resize…", action: onResize)
            Button("Stop", action: onStop).disabled(!machine.isRunning)
        }
    }
}

private struct MachineOverview: View {
    let machine: Machine
    let onResize: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                InspectorSection("Machine") {
                    KeyValueGrid(facts)
                }
                MachineExplainerCard()
                MachineSecurityCard()
                MachineTroubleshootingCard(name: machine.name)
            }
            .padding(Spacing.l)
        }
    }

    private var facts: [(String, String)] {
        var rows: [(String, String)] = [
            ("State", machine.status.rawValue.capitalized),
            ("CPUs", "\(machine.cpus)"),
            ("Memory", ByteCount.format(machine.memory)),
            ("Disk", ByteCount.format(machine.diskSize)),
            // `machine ls` has no image and `machine inspect` may not either (e.g. a machine whose image was
            // deleted); say so instead of an empty row.
            ("Image", machine.image?.reference ?? "Unknown"),
            ("Home folder", HomeMountMode(rawValue: machine.homeMount ?? "")?.title ?? (machine.homeMount ?? "")),
            ("Platform", machine.platform?.slug ?? ""),
        ]
        if let u = machine.userSetup { rows.append(("User", "\(u.username) (uid \(u.uid), gid \(u.gid))")) }
        rows.append(("Created", machine.createdDate.map(RelativeDate.absolute) ?? ""))
        rows.append(("Terminal", "container machine run -n \(machine.name)"))
        return rows.filter { !$0.1.isEmpty }  // blank Home folder / Platform / Created rows read as broken
    }
}

/// "What is a container machine?"
struct MachineExplainerCard: View {
    var body: some View {
        InfoCard(title: "What is a container machine?", symbol: "desktopcomputer") {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("A persistent Linux VM that feels like part of your Mac:")
                Bullet("Your home folder is mapped at **the same path**, so `cd ~/project` works in both.")
                Bullet("A real **init system** runs, so services (sshd, postgres, systemd units) keep running.")
                Bullet("You log in with **your own user name**, with passwordless `sudo`.")
                Bullet("Its disk keeps installed packages across restarts until you delete the machine.")
            }
        }
    }
}

/// Security note from the PRD: full home access, SSH agent, all capabilities, sudo.
struct MachineSecurityCard: View {
    var body: some View {
        InfoCard(title: "Only use images you trust", symbol: "exclamationmark.shield", tint: .statusWarning) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Unlike `container run`, a machine is not a sandbox. It gets:")
                Bullet("**Full read-write access** to your home folder (unless you chose read-only or none).")
                Bullet("Your **SSH agent** — it can use your keys.")
                Bullet("**All Linux capabilities**, no masked paths, and passwordless sudo.")
                Text("Run untrusted code in a regular container instead.")
            }
        }
    }
}

/// "Image doesn't boot?"
struct MachineTroubleshootingCard: View {
    let name: String?

    var body: some View {
        InfoCard(title: "Image doesn't boot?", symbol: "wrench.and.screwdriver", tint: .secondary) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(
                    "The image needs a real `/sbin/init`, `/bin/sh` and `getent`. Docker Hub's `alpine` reboots instantly (“Operation not supported by device”) because its init looks for a missing OpenRC."
                )
                Bullet("Known good: `ghcr.io/linuxcontainers/alpine:3.20`.")
                Bullet("Ubuntu: build the systemd image from Apple's machine docs, then create from it.")
                Bullet("Check the boot log in the **Logs** tab or with `container machine logs \(name ?? "NAME")`.")
            }
        }
    }
}

/// Embedded `container machine run -n NAME` session. Connects on demand: running it boots a stopped machine.
private struct MachineTerminalTab: View {
    let machine: Machine
    @Environment(AppModel.self) private var model
    @State private var session: UUID?
    @State private var exitCode: Int32??

    var body: some View {
        VStack(spacing: 0) {
            if let session {
                TerminalView(command: model.machines.terminalCommand(for: machine.name)) { code in
                    exitCode = .some(code)
                }
                .id(session)
                .padding(Spacing.xs)
                if let exitCode {
                    HStack {
                        Text("Session ended\(exitCode.map { " (exit \($0))" } ?? "").").font(.caption).foregroundStyle(
                            .secondary)
                        Spacer()
                        Button("Reconnect") { connect() }
                    }
                    .padding(Spacing.s)
                    .background(.bar)
                }
            } else {
                ContentUnavailableView {
                    Label("Terminal", systemImage: "apple.terminal")
                } description: {
                    Text(
                        machine.isRunning
                            ? "Opens a login shell as your user in \(machine.name), in the same folder as on your Mac."
                            : "\(machine.name) is stopped. Connecting boots it first, which can take a few seconds.")
                } actions: {
                    Button(machine.isRunning ? "Open Terminal" : "Boot and Open Terminal") { connect() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onAppear { if machine.isRunning { connect() } }
    }

    private func connect() {
        exitCode = nil
        session = UUID()
    }
}

/// `container machine logs NAME` (boot + init output).
private struct MachineLogsTab: View {
    let name: String
    @Environment(AppModel.self) private var model
    @State private var lines: [OutputLine] = []
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Boot and init output").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                    .labelStyle(.iconOnly)
                    .help("Reload logs")
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, Spacing.xs)
            if lines.isEmpty && !loading {
                ContentUnavailableView(
                    "No log output", systemImage: "doc.plaintext",
                    description: Text("The machine hasn't written anything yet."))
            } else {
                OutputLogView(lines: lines, follow: false)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        lines = await model.machines.logs(name)
        loading = false
    }
}

#Preview("Machine detail") {
    @Previewable @State var tab = MachineDetailTab.overview
    MachineDetailView(
        machine: Machine(
            id: "dev", status: .running, cpus: 4, memory: 8 << 30, diskSize: 1 << 30, isDefault: true,
            createdDate: .now),
        tab: $tab, onResize: {}, onStop: {}
    )
    .appModelEnvironment(ResourcePreview.model())
    .frame(width: 460, height: 700)
}
