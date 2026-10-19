import SwiftUI
import ServiceManagement
import AppCore
import DesignSystem

/// Settings scene (⌘,): General · Resources · Engine · Network · Updates · About.
struct SettingsView: View {
    /// UserDefaults key of the selected tab; other views set it (e.g. to `"network"`) before `openSettings()`.
    static let selectedTabKey = "settings.selectedTab"
    @AppStorage(SettingsView.selectedTabKey) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettingsTab() }
            Tab("Resources", systemImage: "cpu", value: "resources") { ResourcesSettingsTab() }
            Tab("Engine", systemImage: "doc.text", value: "engine") { EngineSettingsTab() }
            Tab("Network", systemImage: "network", value: "network") { NetworkSettingsTab() }
            Tab("Updates", systemImage: "arrow.down.circle", value: "updates") { UpdatesSettingsTab() }
            Tab("About", systemImage: "info.circle", value: "about") { AboutSettingsTab() }
        }
        .frame(width: 640, height: 500)
    }
}

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Startup") {
                Toggle("Launch Container Desktop at login", isOn: $settings.launchAtLogin)
                if settings.launchAtLoginRequiresApproval {
                    HStack {
                        Label("Waiting for approval: allow Container Desktop in System Settings → General → Login Items.",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.statusWarning)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                } else if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.statusWarning)
                }
                Toggle("Start the container system when the app launches", isOn: $settings.startEngineOnLaunch)
                Toggle("Show in menu bar", isOn: $settings.menuBarEnabled)
            }
            Section("Containers") {
                Toggle("Show stopped containers", isOn: $settings.showStoppedContainers)
                    .onChange(of: settings.showStoppedContainers) { model.containers.showStopped = settings.showStoppedContainers }
                Toggle("Hide system containers (builder, Kubernetes nodes)", isOn: $settings.hideSystemContainers)
                    .onChange(of: settings.hideSystemContainers) { model.containers.hideSystemManaged = settings.hideSystemContainers }
                LabeledContent("Refresh every") {
                    HStack {
                        Slider(value: $settings.pollingInterval, in: SettingsStore.pollingRange, step: 1)
                            .frame(width: 200)
                        Text("\(Int(settings.pollingInterval)) s").monospacedDigit().frame(width: 36, alignment: .trailing)
                    }
                }
            }
            Section("Notifications & appearance") {
                Toggle("Notify when pulls/builds finish or a container exits", isOn: $settings.notificationsEnabled)
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(SettingsStore.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        // The user can approve or remove the login item in System Settings at any time.
        .onAppear { model.settings.refreshLaunchAtLogin() }
    }
}

struct UpdatesSettingsTab: View {
    var body: some View {
        Form {
            Section("Container Desktop") {
                LabeledContent("Installed version", value: Diagnostics.appVersion)
                Link(destination: URL(string: "https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui/releases")!) {
                    Label("Check on GitHub", systemImage: "arrow.up.right.square")
                }
                Text("Automatic update checks arrive in a later release.").font(.caption).foregroundStyle(.secondary)
            }
            Section("container runtime") {
                Link(destination: URL(string: "https://github.com/apple/container/releases")!) {
                    Label("apple/container releases", systemImage: "arrow.up.right.square")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: Spacing.m) {
                    Image(systemName: "shippingbox.fill").font(.system(size: 40)).foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text("Container Desktop").font(.title2.bold())
                        Text("A native dashboard for Apple’s container runtime").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Versions") {
                LabeledContent("App", value: Diagnostics.appVersion)
                LabeledContent("container CLI", value: model.engine.status?.client?.version ?? "—")
                LabeledContent("container server", value: model.engine.status?.server?.version ?? "—")
                LabeledContent("Backend", value: model.backend.backendDescription)
                LabeledContent("Engine", value: model.engine.label)
            }
            Section("Diagnostics") {
                HStack {
                    Text("Versions, engine state, settings and recent errors — no secrets.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(copied ? "Copied" : "Copy diagnostics") {
                        copyToPasteboard(Diagnostics.report(for: model))
                        copied = true
                    }
                }
            }
            Section {
                Text("MIT License · © AIFLOW LABS LIMITED").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
