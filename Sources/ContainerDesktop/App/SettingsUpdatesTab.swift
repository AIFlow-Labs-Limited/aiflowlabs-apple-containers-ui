import AppCore
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// Settings → Updates: installed vs latest version of the app and of Apple's runtime, how to upgrade each,
/// and the automatic-check switch. The app only links to releases; it never downloads or installs anything.
struct UpdatesSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("Container Desktop") { appRows }
            Section("container runtime") { runtimeRows }
            Section {
                Toggle("Check for updates automatically (once a day)", isOn: $settings.automaticUpdateChecks)
                HStack {
                    Text(lastCheckedText).foregroundStyle(.secondary)
                    Spacer()
                    if model.updates.isChecking { ProgressView().controlSize(.small) }
                    Button("Check Now") { Task { await model.updates.checkNow() } }
                        .disabled(model.updates.isChecking)
                }
                Text("Checks github.com for new releases. Nothing about you or your containers is sent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: App

    @ViewBuilder private var appRows: some View {
        let updates = model.updates
        LabeledContent("Installed", value: updates.installedAppVersion)
        LatestRow(release: updates.latestApp, failure: updates.appFailure)
        if let release = updates.appUpdate {
            UpdateOffer(
                title: "Container Desktop \(release.version) is available",
                actionTitle: "Download", release: release, feed: .app,
                note: "Quit Container Desktop, then replace it in Applications. Your containers keep running.")
        } else if updates.latestApp != nil, SemanticVersion(updates.installedAppVersion) != nil {
            UpToDateRow(text: "Container Desktop is up to date.", release: updates.latestApp)
        } else if SemanticVersion(updates.installedAppVersion) == nil {
            Text("This is a development build, so no update is offered.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Runtime

    @ViewBuilder private var runtimeRows: some View {
        let updates = model.updates
        LabeledContent("Installed", value: installedRuntimeText)
        LatestRow(release: updates.latestRuntime, failure: updates.runtimeFailure)
        LabeledContent("Supported", value: RuntimeSupport.rangeDescription)
        if let notice = RuntimeSupport.notice(for: model.runtimeCompatibility) {
            let tooOld = if case .tooOld = model.runtimeCompatibility { true } else { false }
            Label(notice, systemImage: tooOld ? "exclamationmark.triangle" : "info.circle")
                .font(.callout)
                .foregroundStyle(tooOld ? AnyShapeStyle(.statusWarning) : AnyShapeStyle(.secondary))
        }
        if let release = model.runtimeUpdate {
            UpdateOffer(
                title: "container \(release.version) is available",
                actionTitle: "Open Apple’s Release Page", release: release, feed: .runtime,
                note: "Running containers stop when the runtime is upgraded. Start the container system again "
                    + "afterwards. Homebrew can be a few days behind Apple’s release.")
        } else if updates.latestRuntime != nil, model.installedRuntimeVersion != nil {
            UpToDateRow(text: "The runtime is up to date.", release: updates.latestRuntime)
        }
    }

    private var installedRuntimeText: String {
        if let version = model.installedRuntimeVersion { return version }
        if case .notInstalled = model.engine { return "Not installed" }
        return "Unknown until the container system is running"
    }

    private var lastCheckedText: String {
        guard let date = model.updates.lastChecked else { return "Not checked yet" }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// "Latest" row: the version, "Not checked yet", or "Could not check" with the reason underneath.
private struct LatestRow: View {
    let release: ReleaseInfo?
    let failure: UpdateCheckFailure?

    var body: some View {
        LabeledContent("Latest") {
            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                Text(failure == nil ? (release?.version ?? "Not checked yet") : "Could not check")
                if let failure {
                    Text(failure.explanation + (release.map { " Last known: \($0.version)." } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// "Up to date" line with a link to the release notes.
private struct UpToDateRow: View {
    let text: String
    let release: ReleaseInfo?

    var body: some View {
        HStack {
            Label(text, systemImage: "checkmark.circle").foregroundStyle(.secondary)
            Spacer()
            if let release { Link("Release Notes", destination: release.pageURL) }
        }
        .font(.callout)
    }
}

/// An available update: headline, the button that opens the release page, the Homebrew command, and a note.
private struct UpdateOffer: View {
    let title: String
    let actionTitle: String
    let release: ReleaseInfo
    let feed: ReleaseFeed
    let note: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Label(title, systemImage: "arrow.down.circle.fill").font(.headline)
                Spacer()
                Link("Release Notes", destination: release.pageURL).font(.callout)
                Button(actionTitle) { openURL(release.pageURL) }
                    .buttonStyle(.borderedProminent)
            }
            CopyableCommandRow(title: "Or, if you installed it with Homebrew", command: feed.brewUpgradeCommand)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.xxs)
    }
}

// MARK: Previews

/// Canned GitHub answers for previews: a tag per feed, or `nil` to simulate being offline.
struct PreviewReleases: HTTPFetching {
    var app: String? = "v0.2.0"
    var runtime: String? = "1.7.1"

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        let feed: ReleaseFeed = url == ReleaseFeed.app.latestReleaseAPI ? .app : .runtime
        guard let tag = feed == .app ? app : runtime else { throw URLError(.notConnectedToInternet) }
        let page = "https://github.com/\(feed.repository)/releases/tag/\(tag)"
        return (Data(#"{"tag_name":"\#(tag)","html_url":"\#(page)"}"#.utf8), 200)
    }

    /// A mock-backed model whose update checker answers from these canned releases.
    @MainActor func model(installedApp: String = "0.1.0") -> AppModel {
        let defaults = UserDefaults(suiteName: "ContainerDesktop.previews.updates") ?? .standard
        defaults.removePersistentDomain(forName: "ContainerDesktop.previews.updates")
        let settings = SettingsStore(defaults: defaults)
        let checker = UpdateChecker(
            settings: settings, http: self, defaults: defaults, installedAppVersion: installedApp)
        let model = AppModel(
            backend: MockBackend(), settings: settings,
            buildsHistoryURL: FileManager.default.temporaryDirectory.appending(path: "cd-preview-builds.json"),
            observeAppActivation: false, updates: checker)
        Task {
            await model.refreshEngine()
            await checker.checkNow()
        }
        return model
    }
}

#Preview("Updates available") {
    UpdatesSettingsTab().appModelEnvironment(PreviewReleases().model()).frame(width: 640, height: 560)
}

#Preview("Up to date") {
    UpdatesSettingsTab()
        .appModelEnvironment(PreviewReleases(app: "v0.1.0", runtime: "1.5.0").model())
        .frame(width: 640, height: 560)
}

#Preview("Could not check") {
    UpdatesSettingsTab()
        .appModelEnvironment(PreviewReleases(app: nil, runtime: nil).model())
        .frame(width: 640, height: 560)
}
