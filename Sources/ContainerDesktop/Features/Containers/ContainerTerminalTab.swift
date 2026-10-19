import AppCore
import AppKit
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// Terminal tab: shell picker, embedded `container exec -it` session, or hand-off to Terminal.app.
///
/// `ContainerDetailView` keeps this view mounted (hidden) after it was first shown, so switching to another
/// detail tab does not kill the session. Ending an active session (Reconnect / Close) asks first.
struct ContainerTerminalTab: View {
    let container: Container
    let actions: ContainerActions
    @Environment(AppModel.self) private var model
    @AppStorage("containers.terminal.shell") private var shell = Shell.sh.rawValue
    @AppStorage("containers.terminal.customShell") private var customShell = "/bin/ash"
    @State private var session: UUID?
    /// The command the running session was started with (the picker may change meanwhile).
    @State private var sessionCommand: ContainerKit.CommandLine?
    @State private var exitCode: Int32?
    @State private var exited = false
    @State private var pendingEnd: PendingEnd?

    enum Shell: String, CaseIterable, Identifiable {
        case sh, bash, zsh, custom
        var id: String { rawValue }
        var title: String { self == .custom ? "Custom…" : rawValue }
    }

    private enum PendingEnd: Identifiable {
        case reconnect, close
        var id: Self { self }
    }

    private var isCustom: Bool { shell == Shell.custom.rawValue }
    private var shellError: String? { isCustom ? ContainerShell.validationError(customShell) : nil }
    private var sessionActive: Bool { session != nil && !exited }

    private var command: [String] {
        switch Shell(rawValue: shell) ?? .sh {
        case .custom: return [customShell.trimmingCharacters(in: .whitespaces)]
        case let s: return [s.rawValue]
        }
    }

    private var pickerCommandLine: ContainerKit.CommandLine {
        model.backend.terminalCommand(for: .container(id: container.id, command: command))
    }

    /// What the preview / copy / Terminal.app show: the live session's command while one runs.
    private var shownCommandLine: ContainerKit.CommandLine {
        sessionActive ? (sessionCommand ?? pickerCommandLine) : pickerCommandLine
    }

    var body: some View {
        if !container.isRunning {
            EmptyStateView(
                symbol: "terminal", title: "Container is not running",
                message: "Start \(container.id) to open a shell inside it.",
                actionTitle: "Start"
            ) { actions.start([container.id]) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                controls
                Divider()
                if let session, let sessionCommand {
                    TerminalView(command: sessionCommand) { code in
                        Task { @MainActor in
                            exitCode = code; exited = true
                        }
                    }
                    .id(session)
                    .overlay(alignment: .bottom) { if exited { exitBanner } }
                } else {
                    EmptyStateView(
                        symbol: "terminal", title: "Open a shell",
                        message: shellError ?? "Runs \(Self.quoted(pickerCommandLine))",
                        actionTitle: shellError == nil ? "Open" : nil
                    ) { open() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .confirmationDialog(
                "End the running shell session?",
                isPresented: Binding(
                    get: { pendingEnd != nil }, set: { if !$0 { pendingEnd = nil } }), presenting: pendingEnd
            ) { action in
                Button(action == .reconnect ? "End and Reconnect" : "End Session", role: .destructive) {
                    action == .reconnect ? open() : close()
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Anything running in the shell inside \(container.id) is stopped.")
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Spacing.s) {
            Picker("Shell", selection: $shell) {
                ForEach(Shell.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .fixedSize()
            if isCustom {
                TextField("Shell path", text: $customShell, prompt: Text("/bin/ash"))
                    .textFieldStyle(.roundedBorder)
                    .font(.monoCaption)
                    .frame(width: 160)
                    .onSubmit { if !sessionActive { open() } }
                    .help(shellError ?? "An absolute path or a shell name such as ash, bash, zsh")
                if let shellError {
                    SwiftUI.Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.statusError)
                        .help(shellError)
                        .accessibilityLabel(shellError)
                }
            }
            // No ⌘↩ here: a stray shortcut must not end a live session.
            Button(session == nil ? "Open" : "Reconnect", systemImage: "play.fill") {
                sessionActive ? (pendingEnd = .reconnect) : open()
            }
            .disabled(shellError != nil)
            if session != nil {
                Button("Close", systemImage: "xmark") { sessionActive ? (pendingEnd = .close) : close() }
            }
            Spacer()
            Text(Self.quoted(shownCommandLine))
                .font(.monoCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            CopyButton(Self.quoted(shownCommandLine), label: "Copy command")
            Button("Open in Terminal.app", systemImage: "macwindow", action: openInTerminalApp)
                .disabled(shellError != nil && !sessionActive)
        }
        .controlSize(.small)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.xs + 2)
    }

    private var exitBanner: some View {
        HStack {
            Text(exitCode.map { "Session ended (exit code \($0))." } ?? "Session ended.")
            Button("Reconnect", action: open)
        }
        .font(.callout)
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium))
        .padding(Spacing.m)
    }

    private func open() {
        guard shellError == nil else { return }
        exited = false
        exitCode = nil
        sessionCommand = pickerCommandLine
        session = UUID()
    }

    private func close() {
        session = nil
        sessionCommand = nil
        exited = false
    }

    /// Shell-quoted (`ContainerKit.ShellQuote`), so the line is safe to paste into a shell or run from a script.
    static func quoted(_ command: ContainerKit.CommandLine) -> String { command.display }

    /// Writes a throwaway `.command` script (the backend's command line, shell-quoted) and opens it in
    /// Terminal.app.
    private func openInTerminalApp() {
        let commandLine = shownCommandLine
        let dir = FileManager.default.temporaryDirectory.appending(
            path: "ContainerDesktop", directoryHint: .isDirectory)
        let url = dir.appending(path: "exec-\(container.id)-\(UUID().uuidString.prefix(8)).command")
        let exports = commandLine.environment.sorted { $0.key < $1.key }
            .filter { $0.key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
            .map { "export \($0.key)=\(ShellQuote.quote($0.value))\n" }.joined()
        let script = """
            #!/bin/zsh
            # Generated by Container Desktop — deletes itself after starting.
            rm -f "$0"
            export PATH="/usr/local/bin:$PATH"
            \(exports)exec \(Self.quoted(commandLine))

            """
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
                model.toasts.error("Terminal.app not found")
                return
            }
            NSWorkspace.shared.open(
                [url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil)
        } catch {
            model.toasts.error("Could not open Terminal.app", message: error.localizedDescription)
        }
    }
}

#Preview("Terminal (stopped)") {
    @Previewable @State var ui = ContainersUIState()
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    let c = Container(
        id: "old-job",
        configuration: .init(
            id: "old-job",
            image: ImageReference(
                reference: "alpine", descriptor: Descriptor(digest: "sha256:ab", mediaType: "x", size: 1)),
            creationDate: .now, initProcess: .init(executable: "sh")), status: .init(state: .stopped))
    ContainerTerminalTab(container: c, actions: ContainerActions(model: model, ui: ui))
        .appModelEnvironment(model)
        .frame(width: 800, height: 360)
}
