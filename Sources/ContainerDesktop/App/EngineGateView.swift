import AppCore
import DesignSystem
import SwiftUI

/// Full-content engine states (not installed / stopped / starting / error). Renders `content` only when running.
struct EngineGateView<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder let content: () -> Content

    var body: some View {
        switch model.engine {
        case .running:
            content()
        case .checking:
            ProgressView("Checking the container system…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notInstalled(let paths):
            notInstalled(paths)
        case .stopped:
            stopped
        case .starting:
            VStack(spacing: Spacing.m) {
                ProgressView().controlSize(.large)
                Text("Starting the container system…").font(.title3)
                Text("The first start downloads a Linux kernel and can take a minute.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error(let error):
            VStack(spacing: Spacing.l) {
                Image(systemName: "exclamationmark.octagon")
                    .font(.system(size: 44))
                    .foregroundStyle(.statusError)
                    .accessibilityHidden(true)
                Text("Container Desktop can’t talk to the container system").font(.title2.bold())
                ErrorBanner(error) { Task { await model.refreshEngine() } }
                    .frame(maxWidth: 560)
                Text("Backend: \(model.backend.backendDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Spacing.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func notInstalled(_ paths: [String]) -> some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "shippingbox")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Install Apple’s container runtime").font(.title.bold())
            Text(
                "Container Desktop is a dashboard for the `container` command-line tool. Install it from the official "
                    + "GitHub releases (a signed .pkg), then check again."
            )
            .multilineTextAlignment(.center)
            .frame(maxWidth: 480)
            .foregroundStyle(.secondary)
            HStack(spacing: Spacing.m) {
                Link(destination: URL(string: "https://github.com/apple/container/releases")!) {
                    Label("Download container", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Check again") { Task { await model.refreshEngine() } }
                    .controlSize(.large)
            }
            Text("Looked in: \(paths.joined(separator: ", "))")
                .font(.monoCaption)
                .foregroundStyle(.tertiary)
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stopped: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "power.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("The container system is stopped").font(.title.bold())
            Text("Start it to see and run containers. Nothing runs in the background until you do.")
                .foregroundStyle(.secondary)
            Button {
                Task { await model.startEngine() }
            } label: {
                Label("Start container system", systemImage: "play.fill")
                    .padding(.horizontal, Spacing.s)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(model.engineBusy)
            Text("First run: the system downloads a Linux kernel (about 100 MB) and asks you to confirm.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
