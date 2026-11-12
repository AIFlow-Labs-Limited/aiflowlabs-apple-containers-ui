import AppCore
import AppKit
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI
import UniformTypeIdentifiers

/// "Import Compose File": pick or drop a file → preview (summary, variables, warnings, exact commands) → Run,
/// which streams through `TaskCenter` with per-step status. All logic lives in `ComposeImport` (AppCore).
struct ComposeImportSheet: View {
    let initialURL: URL?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var session = ComposeImport()
    @State private var confirmingReplace = false
    @State private var isVisible = true

    init(url: URL? = nil) { initialURL = url }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ComposeImportFooter(
                session: session, engineRunning: model.engine.isRunning, run: requestRun, close: { dismiss() })
        }
        .frame(width: 780, height: 800)
        .task {
            if let initialURL { session.open(initialURL) }
            await session.refreshEnvironment(backend: model.backend)
        }
        .onChange(of: model.engine.isRunning) {
            Task { await session.refreshEnvironment(backend: model.backend) }
        }
        .onDisappear { isVisible = false }
        .confirmDestructive(
            title: replaceTitle, message: replaceMessage, actionTitle: "Replace and Run",
            isPresented: $confirmingReplace
        ) {
            start()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Import Compose File").font(.title2.bold())
                if let source = session.source {
                    Text((source.url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            if session.source != nil, session.run == nil {
                Button("Choose Another File…") { chooseFile() }.controlSize(.small)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.m)
    }

    @ViewBuilder
    private var content: some View {
        if let run = session.run {
            ComposeRunView(run: run)
        } else if session.source == nil {
            ComposeDropZone(error: session.error, choose: chooseFile) { session.open($0) }
        } else {
            ComposePreviewView(session: session)
        }
    }

    // MARK: Actions

    private func chooseFile() {
        if let url = ComposeFilePanel.choose() { session.open(url) }
    }

    private var replaceTitle: String {
        let names = session.plan?.containersToReplace ?? []
        return names.count == 1 ? "Replace container “\(names[0])”?" : "Replace \(names.count) containers?"
    }

    private var replaceMessage: String {
        let names = session.plan?.containersToReplace ?? []
        return "Deletes \(listed(names)) and creates \(names.count == 1 ? "it" : "them") again from the compose file. "
            + "Running containers are killed first; anything stored only inside them is lost. Named volumes are kept."
    }

    private func requestRun() {
        guard let plan = session.plan, plan.canRun else { return }
        if plan.containersToReplace.isEmpty { start() } else { confirmingReplace = true }
    }

    private func start() {
        let model = model
        let session = session
        session.start(backend: model.backend, taskCenter: model.taskCenter) { succeeded in
            await model.containers.refresh()
            await model.volumes.refresh()
            await model.networks.refresh()
            await model.images.refresh()
            // Jump to the project group, unless the user already closed the sheet and moved on.
            guard succeeded, isVisible, let project = session.run?.plan.projectName else { return }
            ComposeReveal.project(project, in: model)
            dismiss()
        }
    }
}

/// Shows an imported project's group in the Containers list.
@MainActor
enum ComposeReveal {
    static func project(_ name: String, in model: AppModel) {
        UserDefaults.standard.set(true, forKey: "containers.groupByProject")  // the list's "Group by Project"
        model.containers.searchText = ""
        model.navigation.open(.containers, select: ContainerRow.projectPrefix + name)
    }
}

/// The open panel for compose files.
@MainActor
enum ComposeFilePanel {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Compose File"
        panel.message = "Choose a compose.yaml or docker-compose.yml file."
        panel.prompt = "Import"
        panel.allowedContentTypes = [.yaml]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// First step: nothing chosen yet. Drop a file (or its folder) or pick one.
private struct ComposeDropZone: View {
    let error: String?
    let choose: () -> Void
    let open: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: Spacing.l) {
            SwiftUI.Image(systemName: "square.stack.3d.down.right")
                .font(.system(size: 44)).foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text("Drop a compose file here").font(.title3.weight(.semibold))
            Text(
                "compose.yaml or docker-compose.yml. You will see exactly what is created and which commands run "
                    + "before anything starts."
            )
            .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Choose File…", action: choose).keyboardShortcut(.defaultAction)
            if let error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.statusError).font(.callout)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Radius.large)
                .strokeBorder(
                    targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(Spacing.xl)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let file = urls.lazy.compactMap(ComposeLoader.composeFile(at:)).first else { return false }
            open(file)
            return true
        } isTargeted: {
            targeted = $0
        }
    }
}

/// Presents the import sheet for `AppModel.composeRequests` and accepts compose files dropped on the window.
private struct ComposeImportHost: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var requests = model.composeRequests
        content
            .sheet(item: $requests.pending) { request in
                ComposeImportSheet(url: request.url)
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let file = urls.lazy.compactMap(ComposeLoader.composeFile(at:)).first else { return false }
                model.composeRequests.request(file)
                return true
            }
    }
}

extension View {
    /// Attach once, to the main window's root view.
    func composeImportHost() -> some View { modifier(ComposeImportHost()) }
}

#Preview("Compose import") {
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    ComposeImportSheet(url: ComposePreviewSample.url())
        .appModelEnvironment(model)
        .task { await model.refreshEngine() }
}

#Preview("Compose import, no file") {
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    ComposeImportSheet()
        .appModelEnvironment(model)
}
