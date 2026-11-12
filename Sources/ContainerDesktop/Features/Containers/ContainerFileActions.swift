import AppCore
import AppKit
import ContainerKit
import DesignSystem
import SwiftUI

/// Dialog state of the Files tab (name prompt, confirmations, preview).
@MainActor
@Observable
final class FileDialogs {
    enum NamePrompt: Identifiable {
        case newFolder(in: String)
        case rename(path: String)

        var id: String {
            switch self {
            case .newFolder(let folder): return "new:" + folder
            case .rename(let path): return "rename:" + path
            }
        }
    }

    struct PendingUpload {
        let urls: [URL]
        let folder: String
        let conflicts: [String]
    }

    struct PreviewTarget: Identifiable {
        let path: String
        let entry: ContainerFileEntry
        var id: String { path }
    }

    var namePrompt: NamePrompt?
    var pendingDelete: [String] = []
    var pendingUpload: PendingUpload?
    var preview: PreviewTarget?
}

/// File actions shared by the Files tab's path bar, context menu, keyboard shortcuts and drag and drop.
/// Destructive or replacing ones only *request* confirmation through `dialogs`.
@MainActor
struct ContainerFileActions {
    let files: ContainerFilesModel
    let dialogs: FileDialogs

    /// Double-click / Return: enter a folder, preview a file.
    func open(_ row: ContainerFilesModel.Row) {
        guard let entry = row.entry else { return }
        if entry.isBrowsable {
            Task { await files.navigate(to: row.path) }
        } else if entry.kind == .file {
            dialogs.preview = .init(path: row.path, entry: entry)
        }
    }

    /// The folder a drop on `row` goes to: the folder itself, or the folder that contains the row.
    func dropFolder(for row: ContainerFilesModel.Row) -> String {
        if let entry = row.entry { return entry.isBrowsable ? row.path : ContainerPath.parent(of: row.path) }
        return row.path
    }

    func copyPaths(_ paths: [String]) { copyToPasteboard(paths.joined(separator: "\n")) }

    // MARK: Save to Mac

    /// Asks where to save, then copies out through `container cp` as an Activity task.
    func save(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        if paths.count == 1, let path = paths.first {
            let panel = NSSavePanel()
            panel.title = "Save “\(ContainerPath.name(of: path))” to Mac"
            panel.nameFieldStringValue = ContainerPath.name(of: path)
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            files.download([(path, url.path(percentEncoded: false))])
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Save \(paths.count) Items to Mac"
        panel.prompt = "Save Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let items = paths.map { path in
            (path, folder.appending(path: ContainerPath.name(of: path)).path(percentEncoded: false))
        }
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.1) }.map {
            URL(filePath: $0.1).lastPathComponent
        }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = existing.count == 1 ? "Replace “\(existing[0])”?" : "Replace \(existing.count) items?"
            alert.informativeText =
                "\(folder.lastPathComponent) already contains \(existing.prefix(6).joined(separator: ", "))"
                + (existing.count > 6 ? " and \(existing.count - 6) more" : "") + ". Saving replaces them."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        files.download(items)
    }

    // MARK: Upload

    /// Asks which files or folders to upload into `folder`.
    func chooseUploads(into folder: String) {
        let panel = NSOpenPanel()
        panel.title = "Upload to \(folder)"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        upload(panel.urls, into: folder)
    }

    /// Uploads (drag and drop, or the panel). Asks first when something in `folder` would be replaced.
    func upload(_ urls: [URL], into folder: String) {
        let urls = urls.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        let conflicts = files.uploadConflicts(urls, in: folder)
        if conflicts.isEmpty {
            files.upload(urls, into: folder)
        } else {
            dialogs.pendingUpload = .init(urls: urls, folder: folder, conflicts: conflicts)
        }
    }

    // MARK: Delete

    /// Refuses `/`, system directories and mount points; otherwise asks for confirmation.
    func requestDelete(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        if let refusal = paths.lazy.compactMap(files.deletionRefusal).first {
            files.actionError = .other(refusal)
            return
        }
        dialogs.pendingDelete = paths
    }
}

/// New Folder / Rename prompt.
private struct FileNameSheet: View {
    let prompt: FileDialogs.NamePrompt
    let files: ContainerFilesModel
    @State private var name: String

    init(prompt: FileDialogs.NamePrompt, files: ContainerFilesModel) {
        self.prompt = prompt
        self.files = files
        if case .rename(let path) = prompt {
            _name = State(initialValue: ContainerPath.name(of: path))
        } else {
            _name = State(initialValue: "")
        }
    }

    private var problem: String? {
        switch prompt {
        case .newFolder: return ContainerPath.nameProblem(name)
        case .rename(let path): return files.renameProblem(path, to: name)
        }
    }

    var body: some View {
        switch prompt {
        case .newFolder(let folder):
            FormSheet(title: "New Folder", actionTitle: "Create", canSubmit: problem == nil, submit: submit) {
                LabeledContent("In") { Text(folder).font(.monoCaption).textSelection(.enabled) }
                field("Folder name")
            }
        case .rename(let path):
            FormSheet(title: "Rename", actionTitle: "Rename", canSubmit: problem == nil, submit: submit) {
                LabeledContent("Item") { Text(path).font(.monoCaption).textSelection(.enabled) }
                field("New name")
            }
        }
    }

    @ViewBuilder
    private func field(_ title: String) -> some View {
        TextField(title, text: $name)
            .accessibilityLabel(title)
        if let problem, !name.isEmpty { Text(problem).font(.caption).foregroundStyle(.statusError) }
    }

    private func submit() {
        let name = name
        Task {
            switch prompt {
            case .newFolder(let folder): await files.makeFolder(named: name, in: folder)
            case .rename(let path): await files.rename(path, to: name)
            }
        }
    }
}

extension View {
    /// Attaches the Files tab's sheets and confirmations.
    func fileDialogs(_ dialogs: FileDialogs, files: ContainerFilesModel, actions: ContainerFileActions) -> some View {
        @Bindable var dialogs = dialogs
        let deleting = dialogs.pendingDelete
        let upload = dialogs.pendingUpload
        return
            self
            .sheet(item: $dialogs.namePrompt) { FileNameSheet(prompt: $0, files: files) }
            .sheet(item: $dialogs.preview) { target in
                FilePreviewSheet(files: files, path: target.path, entry: target.entry) { actions.save([target.path]) }
            }
            .confirmDestructive(
                title: deleting.count == 1
                    ? "Delete “\(ContainerPath.name(of: deleting[0]))”?" : "Delete \(deleting.count) items?",
                message: "Permanently deletes \(deleting.prefix(8).joined(separator: ", "))"
                    + (deleting.count > 8 ? " and \(deleting.count - 8) more" : "")
                    + " from container “\(files.containerID)”, including everything inside folders. "
                    + "This cannot be undone.",
                actionTitle: "Delete", isPresented: $dialogs.pendingDelete.isPresent
            ) {
                dialogs.pendingDelete = []
                Task { await files.delete(deleting) }
            }
            .confirmDestructive(
                title: (upload?.conflicts.count ?? 0) == 1
                    ? "Replace “\(upload?.conflicts.first ?? "")”?" : "Replace \(upload?.conflicts.count ?? 0) items?",
                message: "\(upload?.folder ?? "") in container “\(files.containerID)” already contains "
                    + "\((upload?.conflicts ?? []).prefix(8).joined(separator: ", ")). Uploading replaces them.",
                actionTitle: "Replace",
                isPresented: Binding(
                    get: { dialogs.pendingUpload != nil }, set: { if !$0 { dialogs.pendingUpload = nil } })
            ) {
                dialogs.pendingUpload = nil
                if let upload { files.upload(upload.urls, into: upload.folder) }
            }
    }
}
