import AppCore
import AppKit
import ContainerKit
import SwiftUI

/// Menu bar commands: View/Window shortcuts plus a DEBUG-only Debug menu.
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Single main window: no File > New Window. ⌘N runs a container from anywhere.
        CommandGroup(replacing: .newItem) {
            Button("Run Container…") {
                openWindow(id: SceneID.main)
                model.navigation.open(.containers)
                model.runRequests.request(RunSpec(image: ""))  // empty spec = blank Run sheet
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(!model.engine.isRunning)
        }
        CommandGroup(after: .sidebar) {
            Button("Command Palette…") { model.navigation.isPaletteOpen = true }
                .keyboardShortcut("k", modifiers: .command)
            Button(model.navigation.isTerminalOpen ? "Hide Terminal" : "Show Terminal") {
                model.navigation.isTerminalOpen.toggle()
            }
            .keyboardShortcut("t", modifiers: .command)
            Button("Refresh") {
                Task { if let section = model.navigation.section { await model.refresh(section) } }
            }
            .keyboardShortcut("r", modifiers: .command)
            Divider()
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { model.navigation.open(section) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        CommandGroup(after: .windowList) {
            Button("Activity") { openWindow(id: SceneID.activity) }
                .keyboardShortcut("0", modifiers: [.command, .shift])
        }
        #if DEBUG
            CommandMenu("Debug") {
                // With the real CLI backend this is a real `container system stop`: say so and confirm.
                Button(DebugLaunchActions.isMockBackend(model) ? "Simulate engine stopped" : "Stop engine (real)…") {
                    if !DebugLaunchActions.isMockBackend(model),
                        !EngineStopConfirmation.confirmModally(
                            model: model, title: "Stop the real container system?",
                            actionTitle: "Stop Engine")
                    {
                        return
                    }
                    Task {
                        try? await model.backend.systemStop()
                        await model.refreshEngine()
                    }
                }
                Button("Simulate engine running") {
                    Task {
                        try? await model.backend.systemStart()
                        await model.refreshEngine()
                    }
                }
                Button("Show sample toasts") {
                    model.toasts.success("Pulled docker.io/library/redis:7", message: "Finished in 4s")
                    model.toasts.error("db exited", message: "docker.io/library/postgres:16-alpine")
                }
                Button("Copy diagnostics") { copyDiagnostics() }
            }
        #endif
    }

    @MainActor private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Diagnostics.report(for: model), forType: .string)
    }
}
