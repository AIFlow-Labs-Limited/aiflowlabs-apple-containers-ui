import Foundation
import ContainerKit

/// Reads a build context folder (local files only, never the CLI): Dockerfile candidates and stage names.
public enum BuildContextInspector {
    /// File names recognised as build definitions, in preference order.
    public static let knownNames = ["Dockerfile", "Containerfile"]

    /// Per-Dockerfile ignore files (`Dockerfile.dockerignore`) look like `Dockerfile.*` but are not build files.
    static let ignoreSuffixes = [".dockerignore", ".containerignore"]

    /// Build definition files in `directory` (top level): `Dockerfile`, `Containerfile`, `*.Dockerfile`,
    /// `Dockerfile.*`, `*.Containerfile` — never `*.dockerignore`. Preferred names first.
    public static func dockerfiles(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let matches = names.filter { name in
            guard !ignoreSuffixes.contains(where: { name.lowercased().hasSuffix($0) }) else { return false }
            return knownNames.contains(name) || knownNames.contains { name.hasPrefix("\($0).") || name.hasSuffix(".\($0)") }
        }
        return matches.sorted { a, b in
            let ra = knownNames.firstIndex(of: a) ?? Int.max, rb = knownNames.firstIndex(of: b) ?? Int.max
            return ra != rb ? ra < rb : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// Named stages (`FROM image AS name`) in Dockerfile text, in order.
    public static func stages(inDockerfile text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let words = line.trimmingCharacters(in: .whitespaces).split(whereSeparator: \.isWhitespace)
            guard words.count >= 4, words[0].uppercased() == "FROM" else { return nil }
            guard let asIndex = words.lastIndex(where: { $0.uppercased() == "AS" }), asIndex + 1 < words.count else { return nil }
            return String(words[asIndex + 1])
        }
    }

    /// Stage names from the Dockerfile at `path` (relative to `directory` unless absolute).
    public static func stages(dockerfile path: String, in directory: URL) -> [String] {
        let url = URL(filePath: resolve(path, against: directory.path(percentEncoded: false)))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return stages(inDockerfile: text)
    }

    // MARK: Paths
    //
    // The CLI resolves relative `-f` and `--secret src=` paths against ITS working directory, and a Finder-launched
    // app has cwd `/`. So every path handed to `container build` is made absolute here: `~` is expanded, relative
    // paths are resolved against the build context.

    /// `~/x` → `/Users/me/x`; other paths unchanged.
    public static func expandTilde(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    /// Absolute form of `path`: `~` expanded, relative paths joined to `context` (itself `~`-expanded), `.`/`..`
    /// collapsed.
    public static func resolve(_ path: String, against context: String) -> String {
        let expanded = expandTilde(path)
        if expanded.hasPrefix("/") { return (expanded as NSString).standardizingPath }
        return ((expandTilde(context) as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}

public extension BuildSpec {
    /// This spec with every path the CLI would otherwise resolve against its own cwd made absolute: the context
    /// (`~` expanded), `-f` (relative to the context) and `--secret …,src=` (relative to the context).
    func resolvingPaths() -> BuildSpec {
        var s = self
        s.contextDirectory = BuildContextInspector.resolve(contextDirectory, against: FileManager.default.currentDirectoryPath)
        if let dockerfile, !dockerfile.isEmpty { s.dockerfile = BuildContextInspector.resolve(dockerfile, against: s.contextDirectory) }
        s.secrets = secrets.map { ResourceValidator.resolvedBuildSecret($0, contextDirectory: s.contextDirectory) }
        return s
    }

    /// The full command the Build sheet previews: `container build …`, shell-quoted.
    var commandPreview: String {
        ContainerKit.CommandLine(executable: "container", arguments: ["build"] + cliArguments).display
    }
}
