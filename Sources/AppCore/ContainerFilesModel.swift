import ContainerKit
import Foundation
import Observation

/// State of the Files tab for one container: the current folder, lazily loaded sub-folders, navigation
/// history and the file actions. Everything goes through `ContainerFileOperations`.
@MainActor
@Observable
public final class ContainerFilesModel {
    /// Entries requested per folder; larger folders are shown truncated.
    public static let entryLimit = 2_000
    private static let showHiddenKey = "containers.files.showHidden"

    /// Load state of one folder.
    public enum FolderState: Equatable, Sendable {
        case loading
        case loaded(ContainerDirectoryListing)
        case failed(BackendError)
    }

    /// One line of the flattened outline.
    public struct Row: Identifiable, Hashable, Sendable {
        /// What the line shows.
        public enum Content: Hashable, Sendable {
            case entry(ContainerFileEntry)
            /// Placeholder while an expanded folder loads.
            case loading
            /// An expanded folder that could not be read.
            case failure(BackendError)
            /// "Showing the first N entries" under a truncated folder.
            case truncated(shown: Int)
            /// An expanded folder with nothing (visible) in it.
            case empty
        }

        /// Unique within the outline: the entry's path, or the folder path plus a marker for placeholders.
        public let id: String
        /// Absolute path of the entry (for placeholders: of the folder they belong to).
        public let path: String
        /// Nesting below the current folder (0 = direct child).
        public let depth: Int
        public let content: Content
        /// The container mount whose destination is this path, if any.
        public let mount: Container.Mount?

        /// The entry, when this row is one.
        public var entry: ContainerFileEntry? {
            if case .entry(let entry) = content { return entry }
            return nil
        }
    }

    public let containerID: String
    /// Mounts of the container, used to mark mount points and to protect them from Delete.
    public var mounts: [Container.Mount]
    /// The folder shown at the top level.
    public private(set) var path = "/"
    /// Load state per folder path (current folder and expanded sub-folders).
    public private(set) var folders: [String: FolderState] = [:]
    /// Folders expanded inline.
    public private(set) var expanded: Set<String> = []
    /// Selected row ids.
    public var selection = Set<String>()
    /// Dot-files visible (remembered across launches).
    public var showHidden: Bool { didSet { defaults.set(showHidden, forKey: Self.showHiddenKey) } }
    /// The last failed action (rename, delete, new folder, typed path…), shown as a banner with its command.
    public var actionError: BackendError?

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored private let taskCenter: TaskCenter
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var backStack: [String] = []
    @ObservationIgnored private var generations: [String: Int] = [:]
    /// Mirrors `backStack.isEmpty` for the Back button.
    public private(set) var canGoBack = false

    /// Creates a model; nothing is loaded until `start()`.
    public init(
        containerID: String, backend: any ContainerBackend, taskCenter: TaskCenter, mounts: [Container.Mount] = [],
        defaults: UserDefaults = .standard
    ) {
        self.containerID = containerID
        self.backend = backend
        self.taskCenter = taskCenter
        self.mounts = mounts
        self.defaults = defaults
        showHidden = defaults.bool(forKey: Self.showHiddenKey)
    }

    // MARK: Derived state

    /// State of the current folder (`nil` before the first load).
    public var currentState: FolderState? { folders[path] }
    public var canGoUp: Bool { path != "/" }

    /// Set when the image has no shell or listing tool: there is nothing to browse, but Export still works.
    public var unavailable: ContainerDirectoryListing.UnavailableReason? {
        if case .loaded(let listing) = currentState { return listing.unavailable }
        return nil
    }

    /// The outline: entries of the current folder with expanded sub-folders inline, folders first.
    public var rows: [Row] {
        var result: [Row] = []
        appendRows(of: path, depth: 0, into: &result)
        return result
    }

    private func appendRows(of folder: String, depth: Int, into rows: inout [Row]) {
        func placeholder(_ content: Row.Content, _ marker: String) -> Row {
            Row(id: folder + "\u{0}" + marker, path: folder, depth: depth, content: content, mount: nil)
        }
        switch folders[folder] {
        case nil, .loading: if depth > 0 { rows.append(placeholder(.loading, "loading")) }
        case .failed(let error): if depth > 0 { rows.append(placeholder(.failure(error), "failure")) }
        case .loaded(let listing):
            let visible = Self.sorted(listing.entries.filter { showHidden || !$0.isHidden })
            for entry in visible {
                let entryPath = ContainerPath.join(folder, entry.name)
                rows.append(
                    Row(
                        id: entryPath, path: entryPath, depth: depth, content: .entry(entry),
                        mount: mount(at: entryPath)))
                if entry.isBrowsable, expanded.contains(entryPath), depth < 32 {
                    appendRows(of: entryPath, depth: depth + 1, into: &rows)
                }
            }
            if visible.isEmpty, depth > 0 { rows.append(placeholder(.empty, "empty")) }
            if listing.isTruncated { rows.append(placeholder(.truncated(shown: listing.entries.count), "truncated")) }
        }
    }

    /// Folders first, then by name the way Finder orders them (`file2` before `file10`).
    static func sorted(_ entries: [ContainerFileEntry]) -> [ContainerFileEntry] {
        entries.sorted { a, b in
            if a.isBrowsable != b.isBrowsable { return a.isBrowsable }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The mount whose destination is exactly `path`.
    public func mount(at path: String) -> Container.Mount? {
        mounts.first { ContainerPath.normalize($0.destination) == path }
    }

    /// The row with this id, if it is still in the outline.
    public func row(id: String) -> Row? { rows.first { $0.id == id } }

    // MARK: Loading and navigation

    /// Loads the current folder if it has not been loaded yet.
    public func start() async {
        if folders[path] == nil { await load(path) }
    }

    /// (Re)loads one folder. A newer load of the same folder wins.
    public func load(_ folder: String) async {
        let generation = (generations[folder] ?? 0) + 1
        generations[folder] = generation
        if case .loaded = folders[folder] {} else { folders[folder] = .loading }
        let state: FolderState
        do {
            state = .loaded(try await backend.listDirectory(containerID, path: folder, limit: Self.entryLimit))
        } catch {
            state = .failed(BackendError(wrapping: error))
        }
        guard generations[folder] == generation else { return }
        folders[folder] = state
    }

    /// Opens `typed` (absolute, or relative to the current folder) as the top-level folder.
    public func navigate(to typed: String) async {
        let target = ContainerPath.normalize(typed.trimmingCharacters(in: .whitespaces), relativeTo: path)
        guard target != path else { return await refresh() }
        backStack.append(path)
        canGoBack = true
        await show(target)
    }

    /// Goes to the parent folder.
    public func goUp() async {
        guard canGoUp else { return }
        await navigate(to: ContainerPath.parent(of: path))
    }

    /// Returns to the previously shown folder.
    public func goBack() async {
        guard let previous = backStack.popLast() else { return }
        canGoBack = !backStack.isEmpty
        await show(previous)
    }

    private func show(_ target: String) async {
        path = target
        selection = []
        actionError = nil
        await load(target)
    }

    /// Reloads the current folder and every expanded folder below it.
    public func refresh() async {
        let visible = [path] + expanded.filter { ContainerPath.isSameOrInside($0, path) }.sorted()
        for folder in visible { await load(folder) }
    }

    /// Expands or collapses a folder inline, loading it the first time.
    public func toggleExpanded(_ folder: String) async {
        if expanded.contains(folder) {
            expanded.remove(folder)
        } else {
            expanded.insert(folder)
            if folders[folder] == nil { await load(folder) }
        }
    }

    // MARK: Actions

    /// Runs a mutating call; on failure stores the error (with its command) and returns `false`.
    private func perform(reloading folder: String, _ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            actionError = nil
            await load(folder)
            return true
        } catch {
            actionError = BackendError(wrapping: error)
            return false
        }
    }

    /// Creates `name` inside `folder`.
    @discardableResult
    public func makeFolder(named name: String, in folder: String) async -> Bool {
        if let problem = ContainerPath.nameProblem(name) {
            actionError = .other(problem)
            return false
        }
        let id = containerID, backend = backend
        return await perform(reloading: folder) {
            try await backend.makeDirectory(id, path: ContainerPath.join(folder, name))
        }
    }

    /// Why `newName` cannot replace the name of `itemPath`, or `nil` when the rename can go ahead.
    public func renameProblem(_ itemPath: String, to newName: String) -> String? {
        if let problem = ContainerPath.nameProblem(newName) { return problem }
        let folder = ContainerPath.parent(of: itemPath)
        if newName == ContainerPath.name(of: itemPath) { return "That is the current name." }
        if case .loaded(let listing) = folders[folder], listing.entries.contains(where: { $0.name == newName }) {
            return "“\(newName)” already exists in this folder."
        }
        return nil
    }

    /// Renames an item within its folder.
    @discardableResult
    public func rename(_ itemPath: String, to newName: String) async -> Bool {
        if let problem = renameProblem(itemPath, to: newName) {
            actionError = .other(problem)
            return false
        }
        let folder = ContainerPath.parent(of: itemPath)
        let id = containerID, backend = backend
        return await perform(reloading: folder) {
            try await backend.moveItem(id, from: itemPath, to: ContainerPath.join(folder, newName))
        }
    }

    /// Why `itemPath` must not be deleted (root, system directory, mount point), or `nil`.
    public func deletionRefusal(_ itemPath: String) -> String? {
        ContainerPath.deletionRefusal(itemPath, mountPoints: mounts.map(\.destination))
    }

    /// Deletes items (after the UI confirmed). Stops at the first failure.
    public func delete(_ paths: [String]) async {
        for itemPath in paths {
            if let refusal = deletionRefusal(itemPath) {
                actionError = .other(refusal)
                return
            }
            let id = containerID, backend = backend
            let done = await perform(reloading: ContainerPath.parent(of: itemPath)) {
                try await backend.deleteItem(id, path: itemPath)
            }
            guard done else { return }
            selection.remove(itemPath)
            expanded = expanded.filter { !ContainerPath.isSameOrInside($0, itemPath) }
        }
    }

    /// Names in `folder` that an upload of `urls` would replace (from the loaded listing).
    public func uploadConflicts(_ urls: [URL], in folder: String) -> [String] {
        guard case .loaded(let listing) = folders[folder] else { return [] }
        let existing = Set(listing.entries.map(\.name))
        return urls.map(\.lastPathComponent).filter(existing.contains)
    }

    /// Copies files or folders from the Mac into `folder` as one Activity task, then reloads the folder.
    @discardableResult
    public func upload(_ urls: [URL], into folder: String) -> LongRunningTask {
        let id = containerID, backend = backend
        var existing: [String] = []
        if case .loaded(let listing) = folders[folder] { existing = listing.entries.map(\.name) }
        let steps = urls.map { url in
            // The Mac often hands out accented names in decomposed form; Linux tools write them precomposed.
            // An item that is replaced keeps the exact bytes of its name (`==` on strings ignores the form).
            let name = url.lastPathComponent
            let destination = ContainerPath.join(
                folder, existing.first { $0 == name } ?? name.precomposedStringWithCanonicalMapping)
            let local = url.path(percentEncoded: false)
            return TaskStep("Copying \(local) to \(id):\(destination)") {
                try await backend.copyIn(id, localPath: local, to: destination)
            }
        }
        let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        return taskCenter.run(
            title: "Upload \(what) to \(id)", steps: steps, summary: "Uploaded \(what) to \(id):\(folder)"
        ) { [weak self] _ in
            await self?.load(folder)
        }
    }

    /// Copies items out of the container as one Activity task. Each pair is (path in container, path on the Mac).
    @discardableResult
    public func download(_ items: [(path: String, localPath: String)]) -> LongRunningTask {
        let id = containerID, backend = backend
        let steps = items.map { item in
            TaskStep("Copying \(id):\(item.path) to \(item.localPath)") {
                try await backend.copyOut(id, path: item.path, to: item.localPath)
            }
        }
        let what = items.count == 1 ? ContainerPath.name(of: items[0].path) : "\(items.count) items"
        return taskCenter.run(title: "Save \(what) from \(id)", steps: steps, summary: "Saved \(what) to the Mac")
    }

    /// Reads at most `FilePreview.byteLimit` bytes of a regular file and classifies them.
    public func preview(_ entry: ContainerFileEntry, at itemPath: String) async throws -> FilePreview {
        let limit = FilePreview.byteLimit
        let data = try await backend.readFile(containerID, path: itemPath, maxBytes: limit + 1)
        return FilePreview.classify(data.prefix(limit), truncated: data.count > limit)
    }
}
