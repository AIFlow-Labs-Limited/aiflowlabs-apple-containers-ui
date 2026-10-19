import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ContainerKit
import ContainerKitMock
import AppCore

/// The one `#Preview` factory for every feature in this folder group (resources + platform).
@MainActor
enum ResourcePreview {
    /// An `AppModel` on `MockBackend` that loads every section (for `#Preview`s).
    static func model() -> AppModel {
        let defaults = UserDefaults(suiteName: "ContainerDesktop.previews") ?? .standard
        let history = FileManager.default.temporaryDirectory.appending(path: "cd-preview-builds.json")
        let model = AppModel(backend: MockBackend(), settings: SettingsStore(defaults: defaults),
                             buildsHistoryURL: history, observeAppActivation: false)
        Task {
            await model.refreshEngine()
            await model.refreshAll()
            await model.builds.refresh()
        }
        return model
    }
}

/// File panels used by the resource features (AppKit, main actor).
@MainActor
enum FilePanels {
    /// Picks one existing file. `types` are file extensions (e.g. `["tar"]`), empty = any.
    static func openFile(title: String, types: [String] = []) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if !types.isEmpty { panel.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) } }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Picks a folder.
    static func openFolder(title: String, startingAt path: String? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let path { panel.directoryURL = URL(filePath: (path as NSString).expandingTildeInPath) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Picks a destination file.
    static func save(title: String, suggestedName: String, type: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        if let utType = UTType(filenameExtension: type) { panel.allowedContentTypes = [utType] }
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Reveals local files in Finder (`~` expanded).
    static func reveal(_ paths: [String]) {
        let urls = paths.map { URL(filePath: ($0 as NSString).expandingTildeInPath) }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
