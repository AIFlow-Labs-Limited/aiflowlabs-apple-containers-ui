import AppCore
import ContainerKit
import DesignSystem
import Foundation

/// Editable state of the Build sheet. Converts to `BuildSpec` (whose `cliArguments` is the single source of truth
/// for the command preview) and is remembered per tag + context so "Rebuild" reopens with the same options.
struct BuildDraft: Codable, Hashable {
    var contextDirectory = ""
    /// `nil` = let the CLI pick `Dockerfile` in the context.
    var dockerfile: String?
    var tag = ""
    var arm64 = true
    var amd64 = false
    var buildArgs: [String] = []
    var target = ""
    var noCache = false
    var pull = false
    var labels: [String] = []
    var secrets: [String] = []
    var forwardSSH = false

    init() {}

    /// Prefill from a history entry (falls back to the remembered draft for the same tag/context).
    init(record: BuildRecord) {
        if let saved = Self.remembered(tag: record.tag, context: record.contextDirectory) {
            self = saved
            return
        }
        contextDirectory = record.contextDirectory
        tag = record.tag
        if !record.platforms.isEmpty {
            arm64 = record.platforms.contains { $0.hasSuffix("arm64") }
            amd64 = record.platforms.contains { $0.hasSuffix("amd64") }
        }
    }

    var platforms: [Platform] {
        // Only pass --platform when the user asked for something other than the native default.
        if arm64 && !amd64 { return [] }
        return (arm64 ? [Platform.arm64] : []) + (amd64 ? [Platform.amd64] : [])
    }

    private static func clean(_ rows: [String]) -> [String] {
        rows.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The command that runs. Every path is absolute (`~` expanded, relative to the context), because the CLI
    /// resolves relative paths against its own working directory — `/` for an app launched from Finder.
    var spec: BuildSpec {
        let trimmedTag = tag.trimmingCharacters(in: .whitespaces)
        var spec = BuildSpec(
            contextDirectory: contextDirectory.isEmpty ? "<context>" : contextDirectory,
            tag: trimmedTag.isEmpty ? "<tag>" : trimmedTag)
        spec.dockerfile = dockerfile
        spec.platforms = platforms
        spec.buildArgs = Self.clean(buildArgs)
        let stage = target.trimmingCharacters(in: .whitespaces)
        spec.target = stage.isEmpty ? nil : stage
        spec.noCache = noCache
        spec.pull = pull
        spec.labels = Self.clean(labels)
        spec.secrets = Self.clean(secrets)
        spec.forwardSSH = forwardSSH
        return contextDirectory.isEmpty ? spec : spec.resolvingPaths()
    }

    /// Problems blocking "Build", in display order.
    var problems: [String] {
        var p: [String] = []
        if contextDirectory.isEmpty { p.append("Choose a context folder.") }
        if tag.trimmingCharacters(in: .whitespaces).isEmpty {
            p.append("Enter a tag.")
        } else if let t = ResourceValidator.imageReference(tag) {
            p.append("Tag: \(t)")
        }
        if !arm64 && !amd64 { p.append("Pick at least one platform.") }
        if !StringRowsEditor.allValid(buildArgs, validate: { ResourceValidator.keyValue($0, allowBareKey: true) }) {
            p.append("Fix the build args.")
        }
        if !StringRowsEditor.allValid(labels, validate: { ResourceValidator.keyValue($0) }) {
            p.append("Fix the labels.")
        }
        if !StringRowsEditor.allValid(secrets, validate: ResourceValidator.buildSecret) { p.append("Fix the secrets.") }
        return p
    }

    // MARK: Memory

    /// Most recently used first; the oldest entries are dropped beyond `maxRemembered`.
    private static let defaultsKey = "builds.drafts.v2"
    static let maxRemembered = 50

    private struct Entry: Codable {
        var key: String
        var draft: BuildDraft
    }

    /// Keyed on the expanded context so `~/app` and `/Users/me/app` are the same draft.
    private static func key(tag: String, context: String) -> String {
        "\(BuildContextInspector.expandTilde(context))|\(tag)"
    }

    private static func load(_ defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func remembered(tag: String, context: String, defaults: UserDefaults = .standard) -> BuildDraft? {
        let k = key(tag: tag, context: context)
        return load(defaults).first { $0.key == k }?.draft
    }

    func remember(defaults: UserDefaults = .standard) {
        let k = Self.key(tag: spec.tag, context: contextDirectory)
        var all = Self.load(defaults).filter { $0.key != k }
        all.insert(Entry(key: k, draft: self), at: 0)
        if all.count > Self.maxRemembered { all.removeLast(all.count - Self.maxRemembered) }
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.defaultsKey) }
        defaults.removeObject(forKey: "builds.drafts")  // v1: an unordered dictionary (random eviction)
    }
}
