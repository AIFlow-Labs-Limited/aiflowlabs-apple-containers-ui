import AppCore
import DesignSystem
import SwiftUI

/// Raw `~/.config/container/config.toml` editor with validation, save and engine restart.
struct EngineSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var original = ""
    @State private var restartPrompt = false

    private var issues: [TOMLIssue] { TOMLValidator.validate(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("~/.config/container/config.toml").font(.monoCaption).foregroundStyle(.secondary)
                Spacer()
                if issues.isEmpty {
                    Label("Valid", systemImage: "checkmark.circle").foregroundStyle(.statusRunning).font(.caption)
                } else {
                    Label(
                        "\(issues.count) issue\(issues.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.statusWarning).font(.caption)
                }
            }
            TextEditor(text: $text)
                .font(.monoBody)
                .scrollContentBackground(.hidden)
                .padding(Spacing.xs)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(.separator))
                .autocorrectionDisabled()
                .accessibilityLabel("config.toml contents")
            if let issue = issues.first {
                Text("Line \(issue.line): \(issue.message)").font(.caption).foregroundStyle(.statusWarning)
            }
            if let error = model.system.lastError {
                ErrorBanner(error, dismiss: { model.system.clearError() })
            }
            HStack {
                Button("Reload") { Task { await load() } }
                Spacer()
                Button("Revert") { text = original }.disabled(text == original)
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text == original || !issues.isEmpty)
                Button("Restart engine") { restartPrompt = true }
                    .help("Stop and start the container system so changes take effect")
            }
        }
        .padding(Spacing.l)
        .task { await load() }
        .confirmDestructive(
            title: "Restart the container system?",
            message: "All running containers are stopped while the engine restarts.",
            actionTitle: "Restart", isPresented: $restartPrompt
        ) {
            Task {
                await model.stopEngine(); await model.startEngine()
            }
        }
    }

    private func load() async {
        await model.system.loadConfigTOML()
        text = model.system.configTOML
        original = text
    }

    private func save() async {
        if await model.system.saveConfigTOML(text) {
            original = text
            model.toasts.success("Saved config.toml", message: "Restart the engine to apply")
        }
    }
}
