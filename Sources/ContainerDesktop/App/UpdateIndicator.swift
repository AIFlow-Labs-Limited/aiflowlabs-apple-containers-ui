import AppCore
import AppKit
import DesignSystem
import SwiftUI

/// Makes the next `openSettings()` land on the Updates tab.
@MainActor
enum UpdatesSettings {
    static func select() { UserDefaults.standard.set("updates", forKey: SettingsView.selectedTabKey) }
}

/// Status bar chip shown only when there is something to say: an app or runtime update is available, or the
/// installed runtime is older than the supported minimum. Clicking opens Settings → Updates. Never a modal.
struct UpdateIndicator: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let summary = model.updateSummary {
            chip("Update available", systemImage: "arrow.down.circle.fill", help: summary)
                .foregroundStyle(.tint)
        } else if case .tooOld = model.runtimeCompatibility,
            let notice = RuntimeSupport.notice(for: model.runtimeCompatibility)
        {
            chip("Runtime too old", systemImage: "exclamationmark.triangle", help: notice)
                .foregroundStyle(.statusWarning)
        }
    }

    private func chip(_ title: String, systemImage: String, help: String) -> some View {
        Button {
            UpdatesSettings.select()
            openSettings()
        } label: {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .help(help + ". Click for details.")
        .accessibilityHint("Opens the Updates settings")
    }
}

/// Menu bar extra item, present only while an update is available.
struct MenuBarUpdateItem: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let summary = model.updateSummary {
            Button("\(summary)…") {
                UpdatesSettings.select()
                openSettings()
                NSApp.activate()
            }
            Divider()
        }
    }
}

/// App menu → "Check for Updates…": opens Settings → Updates and checks right away.
struct CheckForUpdatesCommand: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Check for Updates…") {
            UpdatesSettings.select()
            openSettings()
            Task { await model.updates.checkNow() }
        }
        .disabled(model.updates.isChecking)
    }
}

#Preview("Status bar: update available") {
    StatusBar().appModelEnvironment(PreviewReleases().model()).frame(width: 900)
}

#Preview("Status bar: nothing to report") {
    StatusBar()
        .appModelEnvironment(PreviewReleases(app: "v0.1.0", runtime: "1.5.0").model())
        .frame(width: 900)
}
