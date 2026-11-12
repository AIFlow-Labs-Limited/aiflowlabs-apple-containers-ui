import AppCore
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// The run step: one row per command with its state, the streamed output, and — when it stops early — what was
/// created so far with the option to remove it again.
struct ComposeRunView: View {
    let run: ComposeRun
    @Environment(AppModel.self) private var model
    @State private var confirmingCleanup = false
    @State private var cleanupFailures: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            status
            stepList
            if let task = run.task {
                OutputLogView(buffer: task.buffer, follow: true, showsSearchField: false)
                    .frame(minHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.medium))
                    .overlay(RoundedRectangle(cornerRadius: Radius.medium).strokeBorder(.separator))
            }
            if run.isFinished, !run.succeeded { leftovers }
        }
        .padding(Spacing.xl)
        .confirmDestructive(
            title: "Remove what this run created?",
            message: "Deletes \(run.created.summary). Running containers are killed first, and data written to "
                + "these volumes is lost. Images that were pulled or built are kept, and so is everything that "
                + "existed before the run.",
            actionTitle: "Remove", isPresented: $confirmingCleanup
        ) {
            cleanUp()
        }
    }

    private var status: some View {
        HStack(spacing: Spacing.s) {
            if let task = run.task { TaskStateIcon(state: task.state) }
            Text(headline).font(.headline)
            Spacer()
            Text("\(run.completedCount) of \(run.plan.steps.count) steps").font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if run.succeeded { return "Project \(run.plan.projectName) is up" }
        if let failure = run.failure { return "Stopped: \(failure.step.title) failed" }
        if run.wasCancelled { return "Stopped before finishing" }
        return "Starting project \(run.plan.projectName)…"
    }

    private var stepList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(run.plan.steps) { step in
                    HStack(spacing: Spacing.s) {
                        ComposeStepIcon(state: run.state(of: step)).frame(width: 18)
                        SwiftUI.Image(systemName: step.symbol).foregroundStyle(.secondary).frame(width: 18)
                        Text(step.title).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(label(for: run.state(of: step))).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(Spacing.s)
        }
        .frame(maxHeight: 190)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.medium))
    }

    private func label(for state: ComposeRun.StepState) -> String {
        switch state {
        case .pending: return "Waiting"
        case .running: return "Running"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        case .skipped: return "Not run"
        }
    }

    /// Failure / cancellation: the error with its exact command, then what is left behind.
    @ViewBuilder
    private var leftovers: some View {
        if let failure = run.failure { ErrorBanner(failure.error) }
        if run.created.isEmpty {
            Text(cleanupFailures.isEmpty ? "Nothing was created, so there is nothing to clean up." : "")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Created so far and left in place: \(run.created.summary).")
                    .font(.callout).textSelection(.enabled)
                Spacer()
                if run.isCleaningUp { ProgressView().controlSize(.small) }
                Button("Remove What Was Created…", role: .destructive) { confirmingCleanup = true }
                    .disabled(run.isCleaningUp)
            }
        }
        ForEach(cleanupFailures, id: \.self) { failure in
            Label("Could not remove \(failure)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.statusError).textSelection(.enabled)
        }
    }

    private func cleanUp() {
        let model = model
        Task {
            cleanupFailures = await run.removeCreated(backend: model.backend)
            await model.containers.refresh()
            await model.volumes.refresh()
            await model.networks.refresh()
            if cleanupFailures.isEmpty { model.toasts.success("Removed what the run created") }
        }
    }
}

/// Pending dot / spinner / check / cross / dash for one step.
private struct ComposeStepIcon: View {
    let state: ComposeRun.StepState

    var body: some View {
        switch state {
        case .pending: SwiftUI.Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.small)
        case .succeeded: SwiftUI.Image(systemName: "checkmark.circle.fill").foregroundStyle(.statusRunning)
        case .failed: SwiftUI.Image(systemName: "xmark.octagon.fill").foregroundStyle(.statusError)
        case .skipped: SwiftUI.Image(systemName: "minus.circle").foregroundStyle(.statusStopped)
        }
    }
}

/// A small compose project on disk for `#Preview`s (written to the temporary folder; never touches the runtime).
enum ComposePreviewSample {
    static let yaml = """
        name: shop
        services:
          web:
            image: ghcr.io/example/shop-web:${TAG:-1.4}
            ports: ["8080:3000"]
            environment:
              DATABASE_URL: postgres://shop:secret@db:5432/shop
            depends_on: [db]
            restart: unless-stopped
          db:
            image: postgres:16-alpine
            environment:
              POSTGRES_PASSWORD: secret
            volumes: ["pgdata:/var/lib/postgresql/data"]
            healthcheck:
              test: ["CMD", "pg_isready"]
        volumes:
          pgdata:
        """

    static func url() -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "container-desktop-compose-preview")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "compose.yaml")
        try? Data(yaml.utf8).write(to: url)
        return url
    }
}

#Preview("Compose run") {
    @Previewable @State var session = ComposeImport()
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    Group {
        if let run = session.run { ComposeRunView(run: run) } else { ProgressView() }
    }
    .appModelEnvironment(model)
    .frame(width: 780, height: 640)
    .task {
        session.open(ComposePreviewSample.url())
        await session.refreshEnvironment(backend: model.backend)
        session.start(backend: model.backend, taskCenter: model.taskCenter)
    }
}
