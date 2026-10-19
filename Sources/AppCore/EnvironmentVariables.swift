import Foundation
import ContainerKit

/// A `KEY=VALUE` entry from a container's process environment, with secret masking for display.
///
/// This is the app's single secret detector and masker: the environment tab, image config, Inspect,
/// `RunSpec.commandLineString(maskSecrets:)` and the run sheet all use `isSensitive` / `maskedEntry`.
public struct EnvironmentVariable: Hashable, Sendable, Identifiable {
    public var key: String
    /// `nil` for a bare `KEY` (inherit from the host when passed to `-e`).
    public var value: String?
    /// Position in the list it was parsed from (0-based). Keys can repeat, so rows are identified by position.
    public var ordinal: Int
    /// How many earlier entries in the same list share `key` (0 for the first).
    public var occurrence: Int

    /// Unique within a parsed list: the key for its first occurrence (so selections keyed by name keep working),
    /// `KEY#2`, `KEY#3`… for repeats. Match selections against `id`, not `key`.
    public var id: String { occurrence == 0 ? key : "\(key)#\(occurrence + 1)" }

    public init(key: String, value: String?, ordinal: Int = 0, occurrence: Int = 0) {
        self.key = key
        self.value = value
        self.ordinal = ordinal
        self.occurrence = occurrence
    }

    /// Parses `KEY=VALUE` (value may contain `=`) or a bare `KEY`.
    public init(parsing entry: String, ordinal: Int = 0) {
        if let eq = entry.firstIndex(of: "=") {
            self.init(key: String(entry[..<eq]), value: String(entry[entry.index(after: eq)...]), ordinal: ordinal)
        } else {
            self.init(key: entry, value: nil, ordinal: ordinal)
        }
    }

    // MARK: Secret detection

    /// Fragments that mark a key as secret wherever they appear (case-insensitive).
    public static let sensitiveSubstrings = ["PASSWORD", "PASSWD", "PASSPHRASE", "SECRET", "TOKEN", "KEY", "CREDENTIAL",
                                             "PRIVATE", "AUTHORIZATION", "CERTIFICATE"]
    /// Whole words (split on `_`, `-`, `.`) that mark a key as secret: `DB_PASS`, `GITHUB_PAT`, `X_AUTH`, `TLS_CERT`.
    public static let sensitiveWords = ["PASS", "PWD", "AUTH", "PAT", "CERT", "CREDS", "APIKEY"]

    /// Whether `key` (or a `scheme://user:pass@host` `value`) looks like a secret.
    public static func isSensitive(key: String, value: String? = nil) -> Bool {
        let upper = key.uppercased()
        if sensitiveSubstrings.contains(where: { upper.contains($0) }) { return true }
        let words = upper.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        // `PWD` / `OLDPWD` are the shell's working directories, not passwords.
        let isShellDir = upper == "PWD" || upper == "OLDPWD"
        if !isShellDir, upper.hasSuffix("PWD") || words.contains(where: { sensitiveWords.contains($0) }) { return true }
        if let value, urlCredentialRange(in: value) != nil { return true }
        return false
    }

    /// Whether the value should be hidden by default.
    public var isSensitive: Bool { Self.isSensitive(key: key, value: value) }

    /// Range of the password in `scheme://user:password@host…`, if any.
    static func urlCredentialRange(in value: String) -> Range<String.Index>? {
        guard let match = value.firstMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\/\s:@]*:([^\/\s@]+)@/) else { return nil }
        return match.output.1.startIndex..<match.output.1.endIndex
    }

    /// Masked form of `value`: only the password for credential URLs, else bullets (empty stays empty).
    public static func maskedValue(_ value: String) -> String {
        if let range = urlCredentialRange(in: value) {
            var copy = value
            copy.replaceSubrange(range, with: "••••")
            return copy
        }
        return value.isEmpty ? value : String(repeating: "•", count: min(12, max(6, value.count)))
    }

    /// Value for display: masked for sensitive values unless `reveal` is set.
    public func displayValue(reveal: Bool) -> String {
        guard let value else { return "" }
        if isSensitive && !reveal { return Self.maskedValue(value) }
        return value
    }

    /// `KEY=VALUE` / `KEY`.
    public var entry: String { value.map { "\(key)=\($0)" } ?? key }

    /// `KEY=VALUE` with a sensitive value replaced: `KEY=…` (or the URL with its password masked).
    public var maskedEntry: String {
        guard let value, isSensitive, !value.isEmpty else { return entry }
        return Self.urlCredentialRange(in: value) != nil ? "\(key)=\(Self.maskedValue(value))" : "\(key)=…"
    }

    /// `maskedEntry` for every `KEY=VALUE` entry (bare `KEY` and empty values unchanged).
    public static func masked(_ entries: [String]) -> [String] {
        entries.map { EnvironmentVariable(parsing: $0).maskedEntry }
    }

    /// Whether any entry carries a non-empty sensitive value.
    public static func containsSecrets(_ entries: [String]) -> Bool {
        entries.contains { EnvironmentVariable(parsing: $0).maskedEntry != $0 }
    }

    /// Parses entries, numbering `ordinal` and `occurrence` so every row has a unique `id`.
    public static func parse(_ entries: [String]) -> [EnvironmentVariable] {
        var seen: [String: Int] = [:]
        return entries.enumerated().map { index, entry in
            var v = EnvironmentVariable(parsing: entry, ordinal: index)
            v.occurrence = seen[v.key, default: 0]
            seen[v.key, default: 0] += 1
            return v
        }
    }
}

/// Minimal `.env` parser (Docker `--env-file` semantics plus common quoting): `KEY=VALUE` per line,
/// `#` comments, blank lines ignored, optional `export` prefix (space or tab), surrounding single/double quotes stripped.
public enum DotEnv {
    public static func parse(_ text: String) -> [EnvironmentVariable] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            if line.hasPrefix("export"), let next = line.dropFirst(6).first, next == " " || next == "\t" {
                line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
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

/// POSIX word splitting for the Run sheet's command field (no expansion): whitespace separates words, single
/// quotes are literal, inside double quotes a backslash only escapes `"` `\\` `$` `` ` `` and newline (else it is
/// kept), and a backslash outside quotes escapes the next character.
public enum ShellWords {
    /// Problems `parse` reports.
    public enum ParseError: Error, Hashable, Sendable, CustomStringConvertible {
        case unterminatedQuote(Character)
        public var description: String {
            switch self {
            case .unterminatedQuote(let q): return "Missing closing \(q == "'" ? "single" : "double") quote."
            }
        }
    }

    /// Strict split: throws on an unterminated quote so sheets can flag the field.
    public static func parse(_ text: String) throws(ParseError) -> [String] {
        let (words, openQuote) = scan(text)
        if let openQuote { throw .unterminatedQuote(openQuote) }
        return words
    }

    /// Strict split as an optional: `nil` when a quote is not closed.
    public static func splitIfValid(_ text: String) -> [String]? { try? parse(text) }

    /// Lenient split (an unterminated quote runs to the end of the text). Use `parse` to detect that case.
    public static func split(_ text: String) -> [String] { scan(text).words }

    private static func scan(_ text: String) -> (words: [String], openQuote: Character?) {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var chars = Array(text)[...]
        while let ch = chars.popFirst() {
            switch quote {
            case "'":
                if ch == "'" { quote = nil } else { current.append(ch) }
            case "\"":
                if ch == "\"" {
                    quote = nil
                } else if ch == "\\", let next = chars.first, "\"\\$`\n".contains(next) {
                    chars.removeFirst()
                    if next != "\n" { current.append(next) }      // backslash-newline is a line continuation
                } else {
                    current.append(ch)
                }
            default:
                if ch == "\\" {
                    inWord = true
                    if let next = chars.popFirst() {
                        if next != "\n" { current.append(next) }
                    } else {
                        current.append(ch)                       // trailing backslash stays literal
                    }
                } else if ch == "'" || ch == "\"" {
                    quote = ch; inWord = true
                } else if ch.isWhitespace {
                    if inWord { words.append(current); current = ""; inWord = false }
                } else {
                    current.append(ch); inWord = true
                }
            }
        }
        if inWord { words.append(current) }
        return (words, quote)
    }

    /// Quotes one word for `sh` (delegates to `ContainerKit.ShellQuote`, the app's single quoter).
    public static func quote(_ word: String) -> String { ShellQuote.quote(word) }

    /// Inverse of `split` for display and copy: quotes words that need it.
    public static func join(_ words: [String]) -> String { ShellQuote.join(words) }
}
