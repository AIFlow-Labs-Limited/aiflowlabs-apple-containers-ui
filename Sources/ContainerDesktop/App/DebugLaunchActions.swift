#if DEBUG
import SwiftUI
import AppCore

/// DEBUG-only launch hooks for screenshots and UI smoke tests, e.g.
/// `CONTAINER_DESKTOP_DEBUG_OPEN=palette,section=images swift run ContainerDesktop`.
/// Tokens: `palette`, `settings`, `activity`, `terminal`, `cleanup`, `stopped`, `toasts`, `pull`, `section=<name>`,
/// `select=<id>` (deep-link selection in the current section), `build-sheet` (opens the Build sheet).
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
            case "build-sheet":
                var draft = BuildDraft()
                draft.contextDirectory = "~/src/acdemo"
                draft.tag = "acdemo-api:dev"
                draft.amd64 = true
                draft.buildArgs = ["PYTHON_VERSION=3.11"]
                draft.secrets = ["id=pip,env=PIP_INDEX_TOKEN"]
                draft.noCache = true
                BuildsListView.debugPrefill = draft
                model.navigation.open(.builds, select: BuildsListView.newBuildToken)
            default:
                if token.hasPrefix("section="), let s = SidebarSection(rawValue: String(token.dropFirst(8))) {
                    model.navigation.open(s)
                } else if token.hasPrefix("select="), let s = model.navigation.section {
                    try? await Task.sleep(for: .milliseconds(400))
                    model.navigation.open(s, select: String(token.dropFirst(7)))
                }
            }
        }
    }
}
#endif
