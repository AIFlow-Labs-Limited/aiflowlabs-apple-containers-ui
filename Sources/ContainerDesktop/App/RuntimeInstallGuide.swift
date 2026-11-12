import AppCore
import ContainerKit
import DesignSystem
import SwiftUI

/// The "Not installed" engine screen: three numbered steps from nothing to a running container system.
/// The app does not download or install the runtime itself; it points at Apple's release and at Homebrew.
struct RuntimeInstallGuide: View {
    @Environment(AppModel.self) private var model
    let searchedPaths: [String]

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "shippingbox")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Install Apple’s container runtime").font(.title.bold())
            Text(
                "Container Desktop is a dashboard for Apple’s `container` command-line tool, which is installed "
                    + "separately. It takes about a minute."
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Spacing.l) {
                step(1, "Install the runtime") {
                    HStack(spacing: Spacing.m) {
                        Link(destination: ReleaseFeed.runtime.latestReleasePage) {
                            Label("Download from Apple", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Text("Open the signed .pkg from the latest release.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    CopyableCommandRow(
                        title: "Or install with Homebrew in Terminal", command: ReleaseFeed.brewInstallRuntimeCommand)
                }
                step(2, "Come back and check") {
                    Button("Check Again") { Task { await model.refreshEngine() } }
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                }
                step(3, "Start the container system") {
                    Text(
                        "Once the runtime is found, this screen offers a Start button. It runs "
                            + "`container system start` for you."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)

            VStack(spacing: Spacing.xxs) {
                Text("Works with container \(RuntimeSupport.rangeDescription).")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Looked in: \(searchedPaths.joined(separator: ", "))")
                    .font(.monoCaption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text("\(number)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
                .accessibilityLabel("Step \(number)")
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(title).font(.headline)
                content()
            }
        }
    }
}

#Preview("Runtime not installed") {
    let paths = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]
    let defaults = UserDefaults(suiteName: "ContainerDesktop.previews") ?? .standard
    RuntimeInstallGuide(searchedPaths: paths)
        .appModelEnvironment(
            AppModel(
                backend: UnavailableBackend(searchedPaths: paths), settings: SettingsStore(defaults: defaults),
                buildsHistoryURL: FileManager.default.temporaryDirectory.appending(path: "cd-preview-builds.json"),
                observeAppActivation: false)
        )
        .frame(width: 900, height: 640)
}
