#if DEBUG
import SwiftUI
import AppCore
import ContainerKit

/// DEBUG-only launch hooks for screenshots and UI smoke tests, e.g.
/// `CONTAINER_DESKTOP_DEBUG_OPEN=palette,section=images swift run ContainerDesktop`.
/// Tokens: `palette`, `settings`, `activity`, `terminal`, `cleanup`, `stopped`, `toasts`, `pull`, `section=<name>`,
/// `select=<id>` (deep-link selection in the current section), `build-sheet` (opens the Build sheet),
/// `resources-selftest` (pull/tag/delete + volume/network create/delete through the stores; prints results).
/// platform: `machine-create`, `machine-select`, `cluster-create`, `cluster-select`, `registry-login`, `k8s-demo`, `machine-demo`.
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
            case "resources-selftest":
                await ResourcesSelfTest.run(model: model)
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
            case "k8s-demo":
                // Seed a mock cluster so the Kubernetes screenshot isn't empty.
                await model.clusters.create(ClusterSpec(name: "k8s-dev")).wait()
            case "e2e-machine":
                await PlatformEndToEnd.machine(model: model)
            case "e2e-cluster":
                await PlatformEndToEnd.cluster(model: model)
            case "machine-demo":
                // A running, verified-image machine next to the fixture one.
                var spec = MachineForm().spec
                spec.cpus = 4
                spec.memory = MemorySize(bytes: 8 << 30)
                await model.machines.create(spec).wait()
            case "machine-create", "machine-select", "cluster-create", "cluster-select", "registry-login":
                // Platform sheets/selection (features-platform); the views pick these up.
                DebugPlatformHooks.request(token)
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
