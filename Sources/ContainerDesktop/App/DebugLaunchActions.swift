#if DEBUG
import SwiftUI
import AppCore

/// DEBUG-only launch hooks for screenshots and UI smoke tests, e.g.
/// `CONTAINER_DESKTOP_DEBUG_OPEN=palette,section=images swift run ContainerDesktop`.
/// Tokens: `palette`, `settings`, `activity`, `terminal`, `cleanup`, `stopped`, `toasts`, `pull`, `section=<name>`.
@MainActor
enum DebugLaunchActions {
    static func run(model: AppModel, openWindow: OpenWindowAction, openSettings: OpenSettingsAction) async {
        guard let raw = ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_DEBUG_OPEN"], !raw.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(600))
        for token in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch token {
            case "palette": model.navigation.isPaletteOpen = true
            case "settings": openSettings()
            case "activity": openWindow(id: SceneID.activity)
            case "terminal": model.navigation.isTerminalOpen = true
            case "cleanup": model.navigation.isCleanupOpen = true
            case "toasts":
                model.toasts.success("Pulled docker.io/library/redis:7", message: "Finished in 4s")
            case "pull":
                model.images.pull("docker.io/library/redis:7")
                model.builds.build(.init(contextDirectory: "~/src/acdemo", tag: "acdemo-api:dev"))
            case "stopped":
                try? await model.backend.systemStop()
                await model.refreshEngine()
            default:
                if token.hasPrefix("section="), let s = SidebarSection(rawValue: String(token.dropFirst(8))) {
                    model.navigation.open(s)
                }
            }
        }
    }
}
#endif
