import AppCore
import ContainerKit
import ContainerKitMock
import DesignSystem
import SwiftUI

/// Files tab: browse a running container's filesystem (Docker Desktop's "Files"), with Save to Mac, upload,
/// preview, New Folder, Rename and Delete. A stopped container, or an image without a shell, offers
/// Export Filesystem instead.
struct ContainerFilesTab: View {
    let container: Container
    let actions: ContainerActions
    @Environment(AppModel.self) private var model

    var body: some View {
        if container.isRunning {
            FilesBrowser(
                container: container, actions: actions, files: actions.ui.filesModel(for: container, model: model))
        } else {
            ContentUnavailableView {
                Label("Files need a running container", systemImage: "folder.badge.questionmark")
            } description: {
                Text(
                    "Browsing uses `container exec` and `container cp`, which only work while the container runs. "
                        + "Start it to browse, or export the whole filesystem as a .tar archive.")
            } actions: {
                Button("Start Container") { actions.start([container.id]) }
                    .buttonStyle(.borderedProminent)
                Button("Export Filesystem…") { actions.export(container) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The browser itself: path bar, outline, dialogs.
private struct FilesBrowser: View {
    let container: Container
    let actions: ContainerActions
    @Bindable var files: ContainerFilesModel
    @State private var typedPath = "/"
    @State private var dialogs = FileDialogs()

    private var fileActions: ContainerFileActions { ContainerFileActions(files: files, dialogs: dialogs) }

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            if let error = files.actionError {
                ErrorBanner(error, dismiss: { files.actionError = nil }).padding(Spacing.s)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: container.id) {
            files.mounts = container.configuration.mounts
            typedPath = files.path
            await files.start()
            #if DEBUG
                await applyDebugTokens()
            #endif
        }
        .onChange(of: files.path) { _, new in typedPath = new }
        .fileDialogs(dialogs, files: files, actions: fileActions)
    }

    #if DEBUG
        /// Screenshot hooks, from the same variable as `ContainersDebugHooks`:
        /// `CONTAINER_DESKTOP_DEBUG_OPEN=…,tab=files,files=/app,expand=/app/docs,hidden,preview=/app/app.py`.
        private func applyDebugTokens() async {
            let raw = ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_DEBUG_OPEN"] ?? ""
            for token in raw.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if token.hasPrefix("files=") {
                    await files.navigate(to: String(token.dropFirst(6)))
                } else if token.hasPrefix("expand=") {
                    await files.toggleExpanded(String(token.dropFirst(7)))
                } else if token == "hidden" {
                    files.showHidden = true
                } else if token.hasPrefix("preview="), let row = files.row(id: String(token.dropFirst(8))) {
                    fileActions.open(row)
                }
            }
        }
    #endif

    private var pathBar: some View {
        HStack(spacing: Spacing.s) {
            barButton("Back", "chevron.left") { Task { await files.goBack() } }
                .disabled(!files.canGoBack)
            barButton("Enclosing Folder", "arrow.up") { Task { await files.goUp() } }
                .disabled(!files.canGoUp)
            TextField("Path", text: $typedPath, prompt: Text("/"))
                .textFieldStyle(.roundedBorder)
                .font(.monoBody)
                .onSubmit { Task { await files.navigate(to: typedPath) } }
                .accessibilityLabel("Folder path")
                .help("Type a path and press Return")
            barButton("Refresh", "arrow.clockwise") { Task { await files.refresh() } }
            Toggle(isOn: $files.showHidden) {
                Label("Show Hidden Files", systemImage: files.showHidden ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .labelStyle(.iconOnly)
            .help("Show hidden files (names starting with a dot)")
            Menu {
                Button("Upload Here…", systemImage: "square.and.arrow.down") {
                    fileActions.chooseUploads(into: files.path)
                }
                Button("New Folder…", systemImage: "folder.badge.plus") {
                    dialogs.namePrompt = .newFolder(in: files.path)
                }
                Button("Save Folder to Mac…", systemImage: "square.and.arrow.up") { fileActions.save([files.path]) }
                    .disabled(files.path == "/")
                Button("Copy Path") { copyToPasteboard(files.path) }
                Divider()
                Button("Export Filesystem…", systemImage: "shippingbox") { actions.export(container) }
            } label: {
                Label("Folder Actions", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .labelStyle(.iconOnly)
            .fixedSize()
            .help("Actions for this folder")
            .disabled(files.unavailable != nil)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.s)
    }

    private func barButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { SwiftUI.Image(systemName: symbol) }
            .help(title)
            .accessibilityLabel(title)
    }

    @ViewBuilder
    private var content: some View {
        switch files.currentState {
        case nil, .loading:
            ProgressView("Reading \(files.path)…")
        case .failed(let error):
            VStack(spacing: Spacing.m) {
                ErrorBanner(error, retry: { Task { await files.refresh() } })
                if files.canGoBack { Button("Go Back") { Task { await files.goBack() } } }
            }
            .padding(Spacing.l)
            .frame(maxWidth: 640)
        case .loaded(let listing):
            if listing.unavailable != nil {
                ContentUnavailableView {
                    Label("Files cannot be listed", systemImage: "eye.slash")
                } description: {
                    Text(
                        "This image has no shell or ls, so files cannot be listed. You can still export the filesystem."
                    )
                } actions: {
                    Button("Export Filesystem…") { actions.export(container) }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                ContainerFilesTable(files: files, actions: fileActions)
            }
        }
    }
}

#Preview("Files") {
    @Previewable @State var ui = ContainersUIState()
    let backend = MockBackend()
    let model = AppModel(backend: backend, observeAppActivation: false)
    let container = MockBackend.previewContainer(id: "api", image: "docker.io/library/acdemo-api:latest")
    ContainerFilesTab(container: container, actions: ContainerActions(model: model, ui: ui))
        .appModelEnvironment(model)
        .frame(width: 900, height: 420)
}

#Preview("Files, stopped") {
    @Previewable @State var ui = ContainersUIState()
    let model = AppModel(backend: MockBackend(), observeAppActivation: false)
    let container = MockBackend.previewContainer(
        id: "old-job", image: "docker.io/library/alpine:latest", running: false)
    ContainerFilesTab(container: container, actions: ContainerActions(model: model, ui: ui))
        .appModelEnvironment(model)
        .frame(width: 900, height: 420)
}
