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
///
/// Tokens that change engine state (`stopped`, `pull`, `*-demo`, `resources-selftest`, `e2e-*`) only run against the
/// mock backend unless `CONTAINER_DESKTOP_ALLOW_REAL_ENGINE_TESTS=1` is set. This gate is central: the feature hook
/// files these tokens dispatch to (`ResourcesSelfTest`, `PlatformEndToEnd`, …) are only reached through here.
@MainActor
enum DebugLaunchActions {
    static let allowRealEngineVariable = "CONTAINER_DESKTOP_ALLOW_REAL_ENGINE_TESTS"

    static func isMockBackend(_ model: AppModel) -> Bool { model.backend.backendDescription.hasPrefix("Mock") }

    /// Whether `token` mutates the engine (pulls, stops, creates or deletes resources).
    static func mutatesEngine(_ token: String) -> Bool {
        ["stopped", "pull", "resources-selftest"].contains(token) || token.hasSuffix("-demo") || token.hasPrefix("e2e-")
    }

    static func isAllowed(_ token: String, model: AppModel,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        !mutatesEngine(token) || isMockBackend(model) || environment[allowRealEngineVariable] == "1"
    }

    static func run(model: AppModel, openWindow: OpenWindowAction, openSettings: OpenSettingsAction) async {
        guard let raw = ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_DEBUG_OPEN"], !raw.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(600))
        for token in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard isAllowed(token, model: model) else {
                print("[debug] skipped “\(token)”: it changes the real engine (\(model.backend.backendDescription)). "
                      + "Set \(allowRealEngineVariable)=1 to allow it.")
                continue
            }
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
                model.builds.build(BuildSpec(contextDirectory: "~/src/acdemo", tag: "acdemo-api:dev").resolvingPaths())
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
                // Creates a cluster named "k8s-dev" so the Kubernetes screenshot isn't empty. On the mock backend
                // that is fixture data; on the CLI backend it provisions a REAL cluster (kind node containers), which
                // is why this token, like every `*-demo`, only runs with CONTAINER_DESKTOP_ALLOW_REAL_ENGINE_TESTS=1
                // outside the mock (see `mutatesEngine` / `isAllowed`).
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
