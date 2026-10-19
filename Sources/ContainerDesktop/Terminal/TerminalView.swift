import AppKit
import ContainerKit
import DesignSystem
import SwiftTerm
import SwiftUI

/// Embedded terminal running a `ContainerKit.CommandLine` produced by `backend.terminalCommand(for:)`. Never builds
/// CLI arguments itself. Adds an inset in the terminal's own background colour so the prompt does not touch the
/// pane edge.
struct TerminalView: View {
    let command: ContainerKit.CommandLine
    var fontSize: CGFloat = NSFont.systemFontSize
    var onExit: ((Int32?) -> Void)?

    var body: some View {
        TerminalHostView(command: command, fontSize: fontSize, onExit: onExit)
            .padding(.leading, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .background(Color(nsColor: .textBackgroundColor))  // = SwiftTerm's configureNativeColors() background
    }
}

/// The SwiftTerm `LocalProcessTerminalView` host behind `TerminalView`.
struct TerminalHostView: NSViewRepresentable {
    let command: ContainerKit.CommandLine
    var fontSize: CGFloat = NSFont.systemFontSize
    var onExit: ((Int32?) -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = FocusingTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
        view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        view.configureNativeColors()
        view.processDelegate = context.coordinator
        view.setAccessibilityLabel("Terminal")
        view.startProcess(
            executable: command.executable, args: command.arguments,
            environment: Self.environment(for: command), execName: nil,
            currentDirectory: command.workingDirectory ?? FileManager.default.homeDirectoryForCurrentUser.path)
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.onExit = onExit
        // Re-apply system text colors when the appearance flips between light and dark.
        if context.coordinator.colorScheme != colorScheme {
            context.coordinator.colorScheme = colorScheme
            view.configureNativeColors()
        }
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        view.terminate()
    }

    /// TERM/LANG from SwiftTerm, PATH from the app (plus /usr/local/bin where `container` lives), then overrides.
    static func environment(for command: ContainerKit.CommandLine) -> [String] {
        var env: [String: String] = [:]
        for pair in Terminal.getEnvironmentVariables(termName: "xterm-256color") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { env[parts[0]] = parts[1] }
        }
        var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.split(separator: ":").contains("/usr/local/bin") { path = "/usr/local/bin:" + path }
        env["PATH"] = path
        for (k, v) in command.environment { env[k] = v }
        return env.map { "\($0.key)=\($0.value)" }.sorted()
    }

    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var onExit: ((Int32?) -> Void)?
        var colorScheme: ColorScheme?

        init(onExit: ((Int32?) -> Void)?) { self.onExit = onExit }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) { onExit?(exitCode) }
    }
}

/// Takes keyboard focus as soon as it is on screen: after "Open" / ⌘T the user expects to type straight away,
/// not to click into the terminal first (keys otherwise went to the table behind it).
final class FocusingTerminalView: LocalProcessTerminalView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.makeFirstResponder(self)
    }
}
