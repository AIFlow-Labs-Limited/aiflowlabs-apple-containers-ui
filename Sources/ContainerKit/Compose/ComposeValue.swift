import Foundation
import Yams

/// The YAML document as a plain ordered tree. Scalars stay strings (`5432`, `"5432"` and `yes` are all text
/// until a decoder asks for a number or a boolean), mappings keep file order, anchors/aliases and `<<` merge
/// keys are already resolved. This is the only file that touches Yams.
indirect enum ComposeValue: Hashable, Sendable {
    case null
    case scalar(String)
    case list([ComposeValue])
    case map([Entry])

    struct Entry: Hashable, Sendable {
        var key: String
        var value: ComposeValue
    }

    // MARK: YAML

    /// Parses the first document of `yaml`. An empty document is `.null`.
    static func parse(yaml: String) throws -> ComposeValue {
        do {
            guard let node = try Yams.compose(yaml: yaml) else { return .null }
            return ComposeValue(node)
        } catch let error as YamlError {
            throw ComposeError.invalidYAML(Self.describe(error))
        } catch {
            throw ComposeError.invalidYAML(error.localizedDescription)
        }
    }

    /// "line 4, column 3: did not find expected key" rather than Yams' multi-line dump with a source snippet.
    private static func describe(_ error: YamlError) -> String {
        switch error {
        case .scanner(_, let problem, let mark, _), .parser(_, let problem, let mark, _),
            .composer(_, let problem, let mark, _):
            return "line \(mark.line), column \(mark.column): \(problem)"
        case .duplicatedKeysInMapping(let duplicates, _):
            return "duplicated keys: \(duplicates.joined(separator: ", "))"
        default:
            return String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static let nullLiterals: Set<String> = ["", "~", "null", "Null", "NULL"]

    private init(_ node: Node) {
        switch node {
        case .scalar(let scalar):
            // Only an unquoted null literal is null; `""` is an empty string.
            self = scalar.style == .plain && Self.nullLiterals.contains(scalar.string) ? .null : .scalar(scalar.string)
        case .sequence(let sequence):
            self = .list(sequence.map(ComposeValue.init))
        case .mapping(let mapping):
            var entries: [Entry] = []
            var merged: [Entry] = []
            for (keyNode, valueNode) in mapping {
                let key = keyNode.scalar?.string ?? ""
                let value = ComposeValue(valueNode)
                if key == "<<" {
                    // `<<: *defaults` or `<<: [*a, *b]`: lower priority than the mapping's own keys.
                    let sources = value.listValue ?? [value]
                    for source in sources { merged += source.mapValue ?? [] }
                } else {
                    entries.append(Entry(key: key, value: value))
                }
            }
            for entry in merged where !entries.contains(where: { $0.key == entry.key }) { entries.append(entry) }
            self = .map(entries)
        case .alias:
            self = .null  // Yams resolves aliases while composing; an unresolved one carries no value.
        }
    }

    // MARK: Accessors (all lenient: a wrong shape reads as `nil`)

    var isNull: Bool { self == .null }

    var mapValue: [Entry]? { if case .map(let entries) = self { return entries } else { return nil } }

    var listValue: [ComposeValue]? { if case .list(let items) = self { return items } else { return nil } }

    /// A scalar's text.
    var string: String? { if case .scalar(let text) = self { return text } else { return nil } }

    /// YAML 1.1 booleans, which is what compose files in the wild use (`yes`, `on`, `true`, …).
    var bool: Bool? {
        switch string?.lowercased() {
        case "true", "yes", "on", "y", "1": return true
        case "false", "no", "off", "n", "0": return false
        default: return nil
        }
    }

    var int: Int? { string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    var double: Double? { string.flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }

    /// A scalar as a one-element list, or a list of scalars (non-scalars skipped).
    var stringList: [String]? {
        if let string { return [string] }
        return listValue?.compactMap(\.string)
    }

    /// `{KEY: value}` or `[KEY=value, KEY]` as `KEY=value` entries; a null map value becomes a bare `KEY`.
    var keyValueEntries: [String]? {
        if let entries = mapValue {
            return entries.map { entry in entry.value.string.map { "\(entry.key)=\($0)" } ?? entry.key }
        }
        return listValue?.compactMap(\.string)
    }

    /// `{key: value}` or `[key=value]` as a dictionary (a bare `key` maps to an empty string).
    var stringMap: [String: String]? {
        guard let entries = keyValueEntries else { return nil }
        var result: [String: String] = [:]
        for entry in entries {
            if let eq = entry.firstIndex(of: "=") {
                result[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
            } else {
                result[entry] = ""
            }
        }
        return result
    }

    /// Every scalar in the tree, depth first (mapping keys excluded).
    var scalars: [String] {
        switch self {
        case .null: return []
        case .scalar(let text): return [text]
        case .list(let items): return items.flatMap(\.scalars)
        case .map(let entries): return entries.flatMap(\.value.scalars)
        }
    }

    /// The tree with `transform` applied to every scalar (mapping keys untouched).
    func mapScalars(_ transform: (String) throws -> String) rethrows -> ComposeValue {
        switch self {
        case .null: return .null
        case .scalar(let text): return .scalar(try transform(text))
        case .list(let items): return .list(try items.map { try $0.mapScalars(transform) })
        case .map(let entries):
            return .map(try entries.map { Entry(key: $0.key, value: try $0.value.mapScalars(transform)) })
        }
    }
}

/// Reads keys out of a mapping and remembers which ones were asked for, so everything else can be reported as
/// "not supported" without keeping a second list of known keys in sync.
struct ComposeMapReader {
    private let entries: [ComposeValue.Entry]
    private var consumed = Set<String>()

    init(_ entries: [ComposeValue.Entry]) { self.entries = entries }

    /// The value for `key`, or `nil` when absent or null. Marks the key as handled either way.
    mutating func take(_ key: String) -> ComposeValue? {
        consumed.insert(key)
        guard let value = entries.first(where: { $0.key == key })?.value, !value.isNull else { return nil }
        return value
    }

    /// Whether `key` is present (even with a null value). Marks it as handled.
    mutating func has(_ key: String) -> Bool {
        consumed.insert(key)
        return entries.contains { $0.key == key }
    }

    /// Keys nobody asked for, in file order. `x-…` extension fields are never reported.
    var unhandledKeys: [String] {
        entries.map(\.key).filter { !consumed.contains($0) && !$0.hasPrefix("x-") }
    }
}
