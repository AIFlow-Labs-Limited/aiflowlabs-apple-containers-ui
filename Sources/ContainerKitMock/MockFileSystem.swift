import ContainerKit
import Foundation

/// An in-memory filesystem for one mock container, so the Files tab has something believable to show.
public struct MockFileSystem: Sendable {
    /// A file, directory or link at an absolute path.
    struct Node: Sendable {
        var entry: ContainerFileEntry
        /// File contents; `nil` for directories, links and files that only pretend to have a size.
        var content: Data?
    }

    /// Absolute path → node. The root directory is implicit.
    var nodes: [String: Node] = [:]
    /// `false` simulates a distroless image: listing reports `noShell` and every exec fails.
    public var hasShell = true
    private let epoch: Date

    /// An empty filesystem (just `/`).
    public init(now: Date = .now) { epoch = now }

    // MARK: Building

    /// Adds a directory and any missing parents.
    public mutating func directory(
        _ path: String, mode: UInt16 = 0o755, owner: String = "root", uid: Int = 0, daysOld: Double = 30
    ) {
        let path = ContainerPath.normalize(path)
        guard path != "/" else { return }
        let parent = ContainerPath.parent(of: path)
        if nodes[parent] == nil { directory(parent, owner: owner, uid: uid, daysOld: daysOld) }
        nodes[path] = Node(
            entry: ContainerFileEntry(
                name: ContainerPath.name(of: path), kind: .directory, size: 4096, permissions: mode, uid: uid,
                gid: uid, owner: owner, group: owner, modified: epoch.addingTimeInterval(-86_400 * daysOld)))
    }

    /// Adds a file. `text` becomes its contents; `size` overrides the reported size (large fake binaries).
    public mutating func file(
        _ path: String, _ text: String? = nil, data: Data? = nil, size: Int64? = nil, mode: UInt16 = 0o644,
        owner: String = "root", uid: Int = 0, daysOld: Double = 30
    ) {
        let path = ContainerPath.normalize(path)
        let parent = ContainerPath.parent(of: path)
        if nodes[parent] == nil { directory(parent, owner: owner, uid: uid, daysOld: daysOld) }
        let content = data ?? text.map { Data($0.utf8) }
        nodes[path] = Node(
            entry: ContainerFileEntry(
                name: ContainerPath.name(of: path), kind: .file, size: size ?? Int64(content?.count ?? 0),
                permissions: mode, uid: uid, gid: uid, owner: owner, group: owner,
                modified: epoch.addingTimeInterval(-86_400 * daysOld)),
            content: content)
    }

    /// Adds a symbolic link.
    public mutating func link(_ path: String, to target: String, daysOld: Double = 30) {
        let path = ContainerPath.normalize(path)
        if nodes[ContainerPath.parent(of: path)] == nil { directory(ContainerPath.parent(of: path)) }
        nodes[path] = Node(
            entry: ContainerFileEntry(
                name: ContainerPath.name(of: path), kind: .symlink, size: Int64(target.utf8.count),
                permissions: 0o777, uid: 0, gid: 0, owner: "root", group: "root",
                modified: epoch.addingTimeInterval(-86_400 * daysOld), linkTarget: target))
    }

    // MARK: Queries

    /// Follows symbolic links in every component (at most 16 hops).
    func resolve(_ path: String) -> String {
        var current = ContainerPath.normalize(path)
        for _ in 0..<16 {
            var walked = ""
            var replaced = false
            let parts = current.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                let next = ContainerPath.join(walked.isEmpty ? "/" : walked, part)
                if let target = nodes[next]?.entry.linkTarget {
                    let base = walked.isEmpty ? "/" : walked
                    let rest = parts[(index + 1)...].joined(separator: "/")
                    current = ContainerPath.normalize(
                        rest.isEmpty ? target : target + "/" + rest, relativeTo: base)
                    replaced = true
                    break
                }
                walked = next
            }
            if !replaced { return current }
        }
        return current
    }

    /// `true` when `path` (after following links) is a directory.
    func isDirectory(_ path: String) -> Bool {
        let resolved = resolve(path)
        return resolved == "/" || nodes[resolved]?.entry.kind == .directory
    }

    /// Whether anything exists at exactly `path` (links are not followed).
    func exists(_ path: String) -> Bool { path == "/" || nodes[path] != nil }

    /// Direct children of a directory, with link entries annotated like the real listing.
    func children(of directory: String) -> [ContainerFileEntry] {
        let resolved = resolve(directory)
        return nodes.compactMap { path, node -> ContainerFileEntry? in
            guard ContainerPath.parent(of: path) == resolved else { return nil }
            var entry = node.entry
            if entry.kind == .symlink { entry.linkPointsToDirectory = isDirectory(path) }
            return entry
        }
        .sorted { $0.name < $1.name }
    }

    /// Paths of `path` and everything below it.
    func subtree(_ path: String) -> [String] {
        nodes.keys.filter { ContainerPath.isSameOrInside($0, path) }
    }

    // MARK: Mutations

    /// Removes `path` and everything below it.
    mutating func remove(_ path: String) {
        for key in subtree(path) { nodes[key] = nil }
    }

    /// Moves `source` (and its subtree) to `destination`.
    mutating func move(_ source: String, to destination: String) {
        for key in subtree(source) {
            guard var node = nodes.removeValue(forKey: key) else { continue }
            let moved = destination + key.dropFirst(source.count)
            if key == source { node.entry.name = ContainerPath.name(of: destination) }
            nodes[moved] = node
        }
    }
}
