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
        view.installColors(Self.ansiPalette(for: colorScheme))
        context.coordinator.colorScheme = colorScheme
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
            view.installColors(Self.ansiPalette(for: colorScheme))
        }
    }

    /// The 16 ANSI colours, tuned per appearance so `ls` output stays readable: xterm's stock palette paints
    /// directories in a navy blue that disappears on a dark background. Values follow Terminal.app's Basic profile.
    static func ansiPalette(for scheme: ColorScheme) -> [SwiftTerm.Color] {
        let hex: [UInt32] =
            scheme == .dark
            ? [
                0x3A3A3A, 0xFF6B6B, 0x5FD75F, 0xF0C674, 0x6C9EFF, 0xD58FFF, 0x56D4DD, 0xD0D0D0,
                0x767676, 0xFF8787, 0x8FE88F, 0xFFE08A, 0x8AB4FF, 0xE5A8FF, 0x7FE5EC, 0xFFFFFF,
            ]
            : [
                0x000000, 0xC91B00, 0x00A600, 0x999900, 0x0225C7, 0xA81CA8, 0x0097A7, 0xBFBFBF,
                0x666666, 0xE50000, 0x00B300, 0xB3B300, 0x2A5FD9, 0xE500E5, 0x00B5C2, 0xE5E5E5,
            ]
        return hex.map { rgb in
            SwiftTerm.Color(
                red: UInt16((rgb >> 16) & 0xFF) * 0x101,
                green: UInt16((rgb >> 8) & 0xFF) * 0x101,
                blue: UInt16(rgb & 0xFF) * 0x101)
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
