import AppCore
import ContainerKit
import ContainerKitMock
import DesignSystem
import QuickLook
import SwiftUI

/// Preview of one file in a container: text inline (only the first `FilePreview.byteLimit` bytes are ever
/// read), anything else through Quick Look after copying it to a temporary folder on the Mac.
struct FilePreviewSheet: View {
    /// Files larger than this are not copied out just to look at them.
    static let quickLookByteLimit: Int64 = 200 << 20

    let files: ContainerFilesModel
    let path: String
    let entry: ContainerFileEntry
    let saveToMac: () -> Void

    private enum Phase {
        case loading
        case loaded(FilePreview)
        case failed(BackendError)
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var phase = Phase.loading
    @State private var quickLookURL: URL?
    @State private var quickLookFolder: URL?
    @State private var preparingQuickLook = false
    @State private var quickLookError: BackendError?

    private var canQuickLook: Bool { entry.size <= Self.quickLookByteLimit }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.title3.bold()).lineLimit(1).truncationMode(.middle)
                    Text("\(path) · \(ByteCount.format(entry.size)) · \(entry.modeString) · \(entry.ownerDescription)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer()
                CopyButton(path, label: "Copy path")
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.medium))
            if let quickLookError { ErrorBanner(quickLookError, dismiss: { self.quickLookError = nil }) }
            HStack {
                Button("Quick Look", systemImage: "eye", action: openQuickLook)
                    .disabled(!canQuickLook || preparingQuickLook)
                    .help(
                        canQuickLook
                            ? "Copy the file to a temporary folder on this Mac and open it in Quick Look"
                            : "Too large for Quick Look (over \(ByteCount.format(Self.quickLookByteLimit))). Save it to the Mac instead."
                    )
                if preparingQuickLook { ProgressView().controlSize(.small) }
                Button("Save to Mac…", systemImage: "square.and.arrow.up") {
                    dismiss()
                    saveToMac()
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 720, height: 520)
        .task { await load() }
        .quickLookPreview($quickLookURL)
        .onDisappear {
            if let quickLookFolder { try? FileManager.default.removeItem(at: quickLookFolder) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading: ProgressView("Reading \(entry.name)…")
        case .failed(let error): ErrorBanner(error, retry: { Task { await load() } }).padding(Spacing.m)
        case .loaded(.empty):
            ContentUnavailableView("Empty file", systemImage: "doc", description: Text("This file has no contents."))
        case .loaded(.binary):
            ContentUnavailableView(
                "Binary file", systemImage: "doc.zipper",
                description: Text("This file is not text. Open it with Quick Look or save it to the Mac."))
        case .loaded(.text(let text, let truncated)):
            VStack(spacing: 0) {
                // TextKit-backed and read-only: stays responsive with a few hundred kilobytes of text.
                TextEditor(text: .constant(text))
                    .font(.monoCaption)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Contents of \(entry.name)")
                if truncated {
                    Divider()
                    Text(
                        "Showing the first \(ByteCount.format(FilePreview.byteLimit)) of \(ByteCount.format(entry.size)). Save the file to the Mac to see all of it."
                    )
                    .font(.caption).foregroundStyle(.secondary).padding(Spacing.xs)
                }
            }
        }
    }

    private func load() async {
        phase = .loading
        do {
            phase = .loaded(try await files.preview(entry, at: path))
        } catch {
            phase = .failed(BackendError(wrapping: error))
        }
    }

    private func openQuickLook() {
        let backend = model.backend
        let id = files.containerID
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "ContainerDesktop-preview-\(UUID().uuidString)")
        let target = folder.appending(path: entry.name.replacingOccurrences(of: ":", with: "_"))
        preparingQuickLook = true
        quickLookError = nil
        Task {
            defer { preparingQuickLook = false }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await backend.copyOut(id, path: path, to: target.path(percentEncoded: false))
                quickLookFolder = folder
                quickLookURL = target
            } catch {
                try? FileManager.default.removeItem(at: folder)
                quickLookError = BackendError(wrapping: error)
            }
        }
    }
}

#Preview("File preview") {
    let backend = MockBackend()
    let model = AppModel(backend: backend, observeAppActivation: false)
    let files = ContainerFilesModel(containerID: "api", backend: backend, taskCenter: model.taskCenter)
    FilePreviewSheet(
        files: files, path: "/app/app.py", entry: ContainerFileEntry(name: "app.py", kind: .file, size: 312)
    ) {}
    .appModelEnvironment(model)
}
