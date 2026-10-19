import Foundation

/// A `KEY=VALUE` entry from a container's process environment, with secret masking for display.
public struct EnvironmentVariable: Hashable, Sendable, Identifiable {
    public var key: String
    /// `nil` for a bare `KEY` (inherit from the host when passed to `-e`).
    public var value: String?

    public var id: String { key }

    public init(key: String, value: String?) {
        self.key = key
        self.value = value
    }

    /// Parses `KEY=VALUE` (value may contain `=`) or a bare `KEY`.
    public init(parsing entry: String) {
        if let eq = entry.firstIndex(of: "=") {
            key = String(entry[..<eq])
            value = String(entry[entry.index(after: eq)...])
        } else {
            key = entry
            value = nil
        }
    }

    /// Key fragments that mark a value as secret.
    public static let sensitiveMarkers = ["PASSWORD", "PASSWD", "SECRET", "TOKEN", "KEY"]

    /// Whether the value should be hidden by default (key contains PASSWORD/SECRET/TOKEN/KEY, any case).
    public var isSensitive: Bool {
        let upper = key.uppercased()
        return Self.sensitiveMarkers.contains { upper.contains($0) }
    }

    /// Value for display: bullets for sensitive values unless `reveal` is set.
    public func displayValue(reveal: Bool) -> String {
        guard let value else { return "" }
        if isSensitive && !reveal && !value.isEmpty { return String(repeating: "•", count: min(12, max(6, value.count))) }
        return value
    }

    /// `KEY=VALUE` / `KEY`.
    public var entry: String { value.map { "\(key)=\($0)" } ?? key }

    public static func parse(_ entries: [String]) -> [EnvironmentVariable] { entries.map(EnvironmentVariable.init(parsing:)) }
}

/// Minimal `.env` parser (Docker `--env-file` semantics plus common quoting): `KEY=VALUE` per line,
/// `#` comments, blank lines ignored, optional `export ` prefix, surrounding single/double quotes stripped.
public enum DotEnv {
    public static func parse(_ text: String) -> [EnvironmentVariable] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            var variable = EnvironmentVariable(parsing: line)
            variable.key = variable.key.trimmingCharacters(in: .whitespaces)
            guard !variable.key.isEmpty else { return nil }
            if var v = variable.value {
                v = v.trimmingCharacters(in: .whitespaces)
                if v.count >= 2, let first = v.first, first == v.last, first == "\"" || first == "'" {
                    v = String(v.dropFirst().dropLast())
                }
                variable.value = v
            }
            return variable
        }
    }
}

/// POSIX-ish word splitting for the Run sheet's command field: whitespace separates words, single quotes are
/// literal, double quotes allow `\"` and `\\`, a backslash outside quotes escapes the next character.
public enum ShellWords {
    public static func split(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escape = false
        for ch in text {
            if escape {
                current.append(ch); escape = false; inWord = true
                continue
            }
            switch (quote, ch) {
            case (nil, "\\"), ("\"", "\\"):
                escape = true; inWord = true
            case (nil, "'"), (nil, "\""):
                quote = ch; inWord = true
            case let (q?, c) where c == q:
                quote = nil
            case (nil, let c) where c.isWhitespace:
                if inWord { words.append(current); current = ""; inWord = false }
            default:
                current.append(ch); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    /// Inverse of `split` for display: quotes words that need it.
    public static func join(_ words: [String]) -> String {
        words.map { w in
            guard !w.isEmpty else { return "''" }
            let special = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"$`\\|&;<>()*?!#~"))
            return w.rangeOfCharacter(from: special) == nil ? w : "'" + w.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }
}
