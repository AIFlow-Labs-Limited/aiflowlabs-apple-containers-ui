import AppCore
import AppKit
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

@main
struct ContainerDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.make(mock: { MockBackend() })

    var body: some Scene {
        // One main window: `openWindow(id: SceneID.main)` brings it to the front instead of creating a second one
        // (every window would otherwise share one NavigationModel, palette and terminal).
        Window("Container Desktop", id: SceneID.main) {
            MainWindow()
                .appModelEnvironment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .appModelEnvironment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }

        Window("Activity", id: SceneID.activity) {
            ActivityView()
                .appModelEnvironment(model)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 860, height: 520)

        MenuBarExtra(
            isInserted: Binding(
                get: { model.settings.menuBarEnabled },
                set: { model.settings.menuBarEnabled = $0 })
        ) {
            MenuBarContent()
                .appModelEnvironment(model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

/// Scene identifiers for `openWindow(id:)`.
enum SceneID {
    static let main = "main"
    static let activity = "activity"
}

/// Makes `swift run` behave like a bundled app (Dock icon, frontmost window).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension SettingsStore.Appearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// Menu bar icon: box + running count.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let count = model.containers.runningCount
        if model.engine.isRunning && count > 0 {
            Label("\(count)", systemImage: "shippingbox.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: model.engine.isRunning ? "shippingbox.fill" : "shippingbox")
                .accessibilityLabel("Container Desktop")
        }
    }
}
