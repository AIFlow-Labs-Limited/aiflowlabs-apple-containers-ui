import SwiftUI
import AppKit
import AppCore
import DesignSystem

/// Menu bar extra menu: engine state, running containers (stop), open app, start/stop engine, quit.
/// Freshness: the menu bar extra exists only while `menuBarEnabled`, and then `AppModel.updateBackgroundPolling()`
/// holds a background client on the containers poller (`Poller.startBackground`, every `backgroundPollInterval`),
/// so the list stays current after the main window closes.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Container system: \(model.engine.label)\(model.engine.version.map { " (\($0))" } ?? "")")
        Divider()
        if model.engine.isRunning {
            let running = model.containers.running
            if running.isEmpty {
                Text("No running containers")
            } else {
                Section("Running containers") {
                    ForEach(running) { container in
                        Menu(container.id) {
                            Button("Stop") { Task { await model.containers.stop([container.id]) } }
                            Button("Restart") { Task { await model.containers.restart([container.id]) } }
                            Button("Show in Container Desktop") {
                                model.navigation.open(.containers, select: container.id)
                                openMain()
                            }
                        }
                    }
                }
            }
            Divider()
        }
        Button("Open Container Desktop") { openMain() }
            .keyboardShortcut("o")
        switch model.engine {
        case .running:
            Button("Stop container system…") {
                if EngineStopConfirmation.confirmModally(model: model) { Task { await model.stopEngine() } }
            }
        case .stopped, .error:
            Button("Start container system") { Task { await model.startEngine() } }
        default:
            EmptyView()
        }
        Button("Activity") { openWindow(id: SceneID.activity); NSApp.activate() }
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Container Desktop") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openMain() {
        openWindow(id: SceneID.main)
        NSApp.activate()
    }
}
