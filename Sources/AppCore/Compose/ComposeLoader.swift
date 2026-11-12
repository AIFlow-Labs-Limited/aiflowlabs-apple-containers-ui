import ContainerKit
import Foundation
import Observation

/// A compose file read from disk, with the `.env` file next to it.
public struct ComposeSource: Hashable, Sendable {
    /// The compose file.
    public var url: URL
    /// Its text.
    public var text: String
    /// Variables from the `.env` file in the same folder (empty when there is none).
    public var dotEnv: [String: String]
    /// Whether a `.env` file was found.
    public var hasDotEnv: Bool
    /// Override files in the same folder (`compose.override.yaml`, …). Docker Compose merges them; the app does not.
    public var overrideFiles: [String]

    /// Absolute path of the folder the file is in; relative paths in the file resolve against it.
    public var directory: String { url.deletingLastPathComponent().path(percentEncoded: false) }
    /// File name for titles.
    public var fileName: String { url.lastPathComponent }
}

/// Reads compose files (local files only; never the CLI).
public enum ComposeLoader {
    /// Names Docker Compose looks for, in its order of preference.
    public static let standardFileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]
    /// Override files Docker Compose would merge on top of the standard ones.
    public static let overrideFileNames = [
        "compose.override.yaml", "compose.override.yml", "docker-compose.override.yaml", "docker-compose.override.yml",
    ]
    /// Larger files are refused: a compose file is a few kilobytes.
    public static let maximumSize = 2 << 20

    /// Whether `url` could be a compose file: any `.yaml` / `.yml` file.
    public static func isCandidate(_ url: URL) -> Bool {
        ["yaml", "yml"].contains(url.pathExtension.lowercased())
    }

    /// For a dropped item: the file itself when it is YAML, or the standard compose file inside a dropped folder.
    public static func composeFile(at url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue { return isCandidate(url) ? url : nil }
        return standardFileNames.map { url.appending(path: $0) }.first {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    /// Reads `url` and the `.env` next to it.
    /// - Throws: `BackendError.other` with a readable message when the file cannot be read.
    public static func load(_ url: URL) throws -> ComposeSource {
        let path = url.path(percentEncoded: false)
        guard let data = FileManager.default.contents(atPath: path) else {
            throw BackendError.other("“\(url.lastPathComponent)” could not be read.")
        }
        guard data.count <= maximumSize else {
            throw BackendError.other("“\(url.lastPathComponent)” is too large to be a compose file.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw BackendError.other("“\(url.lastPathComponent)” is not a UTF-8 text file.")
        }
        let folder = url.deletingLastPathComponent()
        let envData = FileManager.default.contents(atPath: folder.appending(path: ".env").path(percentEncoded: false))
        var dotEnv: [String: String] = [:]
        for variable in DotEnv.parse(envData.map { String(decoding: $0, as: UTF8.self) } ?? "") {
            dotEnv[variable.key] = variable.value ?? ""
        }
        let overrides = overrideFileNames.filter {
            $0 != url.lastPathComponent
                && FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false))
        }
        return ComposeSource(url: url, text: text, dotEnv: dotEnv, hasDotEnv: envData != nil, overrideFiles: overrides)
    }
}

/// Hand-off from the menus, the command palette, the Containers toolbar and drag-and-drop to the window's
/// "Import Compose File" sheet (same pattern as `RunRequests`).
@MainActor
@Observable
public final class ComposeImportRequests {
    /// One request to show the import sheet.
    public struct Request: Identifiable, Hashable, Sendable {
        public let id = UUID()
        /// File to open straight away; `nil` shows the "choose a file" step.
        public var url: URL?
    }

    /// The request waiting to be shown. The window binds its sheet to this and clears it on dismissal.
    public var pending: Request?

    public init() {}

    /// Asks for the import sheet, optionally with a file already chosen (replaces an earlier request).
    public func request(_ url: URL? = nil) { pending = Request(url: url) }
}
