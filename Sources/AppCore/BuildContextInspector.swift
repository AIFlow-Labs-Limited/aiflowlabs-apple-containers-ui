import Foundation
import ContainerKit

/// Reads a build context folder (local files only, never the CLI): Dockerfile candidates and stage names.
public enum BuildContextInspector {
    /// File names recognised as build definitions, in preference order.
    public static let knownNames = ["Dockerfile", "Containerfile"]

    /// Build definition files in `directory` (top level): `Dockerfile`, `Containerfile`, `*.Dockerfile`,
    /// `Dockerfile.*`, `*.Containerfile`. Preferred names first.
    public static func dockerfiles(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let matches = names.filter { name in
            knownNames.contains(name) || knownNames.contains { name.hasPrefix("\($0).") || name.hasSuffix(".\($0)") }
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
        let url = path.hasPrefix("/") ? URL(filePath: path) : directory.appending(path: path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return stages(inDockerfile: text)
    }
}

public extension BuildSpec {
    /// The full command the Build sheet previews: `container build …`, shell-quoted.
    var commandPreview: String {
        ContainerKit.CommandLine(executable: "container", arguments: ["build"] + cliArguments).display
    }
}
