import Foundation

/// A problem found by `TOMLValidator`.
public struct TOMLIssue: Hashable, Sendable {
    public var line: Int
    public var message: String
    public init(line: Int, message: String) { self.line = line; self.message = message }
}

/// Line-level structure of a TOML document shared by the validator and the editor. Not a full TOML parser: it
/// understands headers, `key = value` lines (bare, quoted and dotted keys), inline comments, and values that
/// span lines (multi-line arrays, `"""` and `'''` strings). LF and CRLF line endings are both accepted.
struct TOMLDocument {
    enum Kind {
        case header(path: [String], isArray: Bool)
        case keyValue(keyText: String, key: [String], value: String)
        case invalid(String)
    }

    struct Entry {
        var kind: Kind
        /// 0-based line range in `lines` (multi-line values span several lines).
        var lines: ClosedRange<Int>
        /// Table the entry belongs to (`[]` = root); for headers, the header's own path.
        var table: [String]
    }

    var lines: [String]
    /// `"\r\n"` when the source used CRLF, else `"\n"`.
    var newline: String
    var hadTrailingNewline: Bool
    var entries: [Entry] = []
    /// Line and message of an unterminated multi-line construct at end of input.
    var unterminated: (line: Int, message: String)?

    init(_ text: String) {
        newline = text.contains("\r\n") ? "\r\n" : "\n"
        var raw = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        hadTrailingNewline = raw.count > 1 && raw.last == ""
        if hadTrailingNewline { raw.removeLast() }
        if text.isEmpty { raw = [] }
        lines = raw
        parse()
    }

    func render() -> String {
        var result = lines.joined(separator: newline)
        if !lines.isEmpty { result += newline }
        return result
    }

    private mutating func parse() {
        var table: [String] = []
        var i = 0
        while i < lines.count {
            let start = i
            let content = Self.stripComment(lines[i]).trimmingCharacters(in: .whitespaces)
            i += 1
            if content.isEmpty { continue }

            if content.hasPrefix("[") {
                let isArray = content.hasPrefix("[[")
                let close = isArray ? "]]" : "]"
                guard content.hasSuffix(close), content.count >= (isArray ? 4 : 2) else {
                    entries.append(
                        Entry(
                            kind: .invalid("Section header is missing “\(close)”"), lines: start...start, table: table))
                    continue
                }
                let name = String(content.dropFirst(isArray ? 2 : 1).dropLast(isArray ? 2 : 1))
                guard let path = Self.parseKey(name) else {
                    let shown = name.trimmingCharacters(in: .whitespaces)
                    entries.append(
                        Entry(kind: .invalid("Invalid section name “\(shown)”"), lines: start...start, table: table))
                    continue
                }
                table = path
                entries.append(Entry(kind: .header(path: path, isArray: isArray), lines: start...start, table: path))
                continue
            }

            guard let eq = Self.firstUnquotedEquals(in: content) else {
                entries.append(Entry(kind: .invalid("Expected “key = value”"), lines: start...start, table: table))
                continue
            }
            let keyText = content[..<eq].trimmingCharacters(in: .whitespaces)
            var value = content[content.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard let key = Self.parseKey(keyText) else {
                entries.append(Entry(kind: .invalid("Invalid key “\(keyText)”"), lines: start...start, table: table))
                continue
            }
            if value.isEmpty {
                entries.append(
                    Entry(kind: .invalid("Missing value for “\(keyText)”"), lines: start...start, table: table))
                continue
            }

            // Values that continue on following lines.
            for delimiter in ["\"\"\"", "'''"] where value.hasPrefix(delimiter) {
                if !value.dropFirst(3).contains(delimiter) {
                    while i < lines.count, !lines[i].contains(delimiter) { i += 1 }
                    if i == lines.count {
                        unterminated = (start + 1, "Unterminated multi-line string")
                    } else {
                        i += 1
                    }
                }
            }
            if value.hasPrefix("[") {
                var depth = Self.bracketDelta(value)
                while depth > 0, i < lines.count {
                    let next = Self.stripComment(lines[i])
                    depth += Self.bracketDelta(next)
                    value += "\n" + next.trimmingCharacters(in: .whitespaces)
                    i += 1
                }
                if depth > 0 { unterminated = (start + 1, "Unterminated array") }
            }
            entries.append(
                Entry(kind: .keyValue(keyText: keyText, key: key, value: value), lines: start...(i - 1), table: table))
        }
    }

    // MARK: Lexical helpers

    /// Splits `a.b."c.d"` into `["a", "b", "c.d"]`. Bare parts allow `A-Za-z0-9_-` only (no spaces); quoted parts
    /// use `"…"` or `'…'`. Whitespace around dots is allowed. `nil` when invalid.
    static func parseKey(_ text: String) -> [String]? {
        var parts: [String] = []
        var rest = Substring(text)
        while true {
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = rest.first else { return nil }
            if first == "\"" || first == "'" {
                guard let close = rest.dropFirst().firstIndex(of: first) else { return nil }
                parts.append(String(rest[rest.index(after: rest.startIndex)..<close]))
                rest = rest[rest.index(after: close)...]
            } else {
                let bare = rest.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
                guard !bare.isEmpty else { return nil }
                parts.append(String(bare))
                rest = rest.dropFirst(bare.count)
            }
            rest = rest.drop(while: { $0 == " " || $0 == "\t" })
            if rest.isEmpty { return parts }
            guard rest.first == "." else { return nil }
            rest = rest.dropFirst()
        }
    }

    static func firstUnquotedEquals(in line: String) -> String.Index? {
        var quote: Character?
        for i in line.indices {
            let ch = line[i]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "=" {
                return i
            }
        }
        return nil
    }

    /// Drops a trailing `# comment` that is outside strings (basic strings honour `\"`).
    static func stripComment(_ line: String) -> String { String(line[..<commentStart(line)]) }

    /// Index where an inline comment (including whitespace before it) begins, or `endIndex`.
    static func commentStart(_ line: String) -> String.Index {
        var quote: Character?
        var escaped = false
        for i in line.indices {
            let ch = line[i]
            if let q = quote {
                if escaped { escaped = false; continue }
                if ch == "\\" && q == "\"" { escaped = true; continue }
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "#" {
                var start = i
                while start > line.startIndex, line[line.index(before: start)].isWhitespace {
                    start = line.index(before: start)
                }
                return start
            }
        }
        return line.endIndex
    }

    static func bracketDelta(_ s: String) -> Int {
        var depth = 0
        var quote: Character?
        var escaped = false
        for ch in s {
            if let q = quote {
                if escaped { escaped = false; continue }
                if ch == "\\" && q == "\"" { escaped = true; continue }
                if ch == q { quote = nil }
                continue
            }
            switch ch {
            case "\"", "'": quote = ch
            case "[": depth += 1
            case "]": depth -= 1
            default: break
            }
        }
        return depth
    }

    /// Whether a single-line string value is terminated.
    static func isTerminatedString(_ value: String) -> Bool {
        guard let q = value.first, q == "\"" || q == "'" else { return true }
        var escaped = false
        for ch in value.dropFirst() {
            if escaped { escaped = false; continue }
            if ch == "\\" && q == "\"" { escaped = true; continue }
            if ch == q { return true }
        }
        return false
    }
}

/// Tiny structural validator for `config.toml` — not a TOML parser. Catches what users typically break when
/// hand-editing: unbalanced `[section]` headers, lines that are not `key = value`, invalid keys (bare keys
/// cannot contain spaces), unterminated strings/arrays, duplicate sections and keys — including a `[table]`
/// that redefines one already created by a dotted key (`container.cpus = 2` then `[container]`).
public enum TOMLValidator {
    public static func validate(_ text: String) -> [TOMLIssue] {
        let doc = TOMLDocument(text)
        var issues: [TOMLIssue] = []
        var explicitTables = Set<[String]>()
        var implicitTables = Set<[String]>()  // created by dotted keys
        var keys = Set<[String]>()
        // Keys of each `[[array]]` element live in their own namespace.
        var scope: [String] = []
        var arrayElements = 0

        for entry in doc.entries {
            let line = entry.lines.lowerBound + 1
            switch entry.kind {
            case .invalid(let message):
                issues.append(TOMLIssue(line: line, message: message))
            case .header(let path, let isArray):
                if isArray {
                    arrayElements += 1
                    scope = path + ["[\(arrayElements)]"]
                    continue
                }
                scope = path
                let name = path.joined(separator: ".")
                if explicitTables.contains(path) || implicitTables.contains(path) || keys.contains(path) {
                    issues.append(TOMLIssue(line: line, message: "Duplicate section [\(name)]"))
                }
                explicitTables.insert(path)
            case .keyValue(let keyText, let key, let value):
                let full = scope + key
                if keys.contains(full) || explicitTables.contains(full) {
                    issues.append(TOMLIssue(line: line, message: "Duplicate key “\(keyText)”"))
                }
                keys.insert(full)
                for n in stride(from: scope.count + 1, to: full.count, by: 1) {
                    implicitTables.insert(Array(full.prefix(n)))
                }
                if !value.hasPrefix("\"\"\"") && !value.hasPrefix("'''") && !TOMLDocument.isTerminatedString(value) {
                    issues.append(TOMLIssue(line: line, message: "Unterminated string"))
                }
            }
        }
        if let (line, message) = doc.unterminated { issues.append(TOMLIssue(line: line, message: message)) }
        return issues
    }

    /// Bare or quoted, optionally dotted key (`cpus`, `"a b"`, `container.cpus`).
    static func isValidKey(_ key: String) -> Bool { TOMLDocument.parseKey(key) != nil }

    /// Drops a trailing `# comment` that is outside quotes.
    static func stripComment(_ line: String) -> String { TOMLDocument.stripComment(line) }

    static func bracketDelta(_ s: String) -> Int { TOMLDocument.bracketDelta(s) }
}

/// Line-based edits of simple `key = value` pairs, preserving comments, indentation, line endings and
/// formatting elsewhere. Used by Settings → Resources to set `[container] cpus = 4` etc. Understands keys
/// written as dotted keys (`container.cpus = 4` at the root) and values spanning several lines.
public enum TOMLEditor {
    /// Raw value text (`4`, `"8g"`) of `key` in `[section]` (or `section.key` written as a dotted key), or nil.
    public static func value(_ key: String, section: String, in text: String) -> String? {
        let doc = TOMLDocument(text)
        guard let index = find(key, section: section, in: doc),
            case .keyValue(_, _, let value) = doc.entries[index].kind
        else { return nil }
        return value
    }

    /// Unquoted string value.
    public static func stringValue(_ key: String, section: String, in text: String) -> String? {
        value(key, section: section, in: text).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    }

    /// Sets (or with `nil` removes) `key = rawValue` in `[section]`, creating the section when needed.
    public static func setting(_ key: String, to rawValue: String?, section: String, in text: String) -> String {
        var doc = TOMLDocument(text)
        let target = path(section) + [key]

        if let index = find(key, section: section, in: doc) {
            let entry = doc.entries[index]
            guard let rawValue else {
                doc.lines.removeSubrange(entry.lines)
                return doc.render()
            }
            guard case .keyValue(let keyText, _, _) = entry.kind else { return text }
            let first = doc.lines[entry.lines.lowerBound]
            let last = doc.lines[entry.lines.upperBound]
            let indent = String(first.prefix(while: { $0 == " " || $0 == "\t" }))
            let comment = String(last[TOMLDocument.commentStart(last)...])
            doc.lines.replaceSubrange(entry.lines, with: ["\(indent)\(keyText) = \(rawValue)\(comment)"])
            return doc.render()
        }
        guard let rawValue else { return text }

        let tablePath = path(section)
        let headerIndex = doc.entries.lastIndex {
            if case .header(let p, false) = $0.kind { return p == tablePath } else { return false }
        }
        if tablePath.isEmpty || headerIndex != nil {
            // Insert after the last entry of that table (root: before the first header).
            let members = doc.entries.indices.filter { i in
                if case .header = doc.entries[i].kind { return false }
                return doc.entries[i].table == tablePath && (headerIndex.map { i > $0 } ?? true)
            }
            let insertAt: Int
            if let lastMember = members.last {
                insertAt = doc.entries[lastMember].lines.upperBound + 1
            } else if let headerIndex {
                insertAt = doc.entries[headerIndex].lines.upperBound + 1
            } else {
                insertAt =
                    doc.entries.first { if case .header = $0.kind { true } else { false } }?.lines.lowerBound
                    ?? doc.lines.count
            }
            doc.lines.insert("\(key) = \(rawValue)", at: insertAt)
            return doc.render()
        }
        // No `[section]` header. If dotted keys already create that table, adding `[section]` would redefine it.
        let dotted = doc.entries.lastIndex { e in
            if case .keyValue(_, let k, _) = e.kind {
                return Array((e.table + k).prefix(tablePath.count)) == tablePath && e.table.count < tablePath.count
            }
            return false
        }
        if let dotted, case .keyValue(_, _, _) = doc.entries[dotted].kind {
            let entry = doc.entries[dotted]
            let prefix = Array(target.dropFirst(entry.table.count)).map(quoteKeyPart).joined(separator: ".")
            doc.lines.insert("\(prefix) = \(rawValue)", at: entry.lines.upperBound + 1)
            return doc.render()
        }
        while let last = doc.lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { doc.lines.removeLast() }
        if !doc.lines.isEmpty { doc.lines.append("") }
        doc.lines += ["[\(tablePath.map(quoteKeyPart).joined(separator: "."))]", "\(key) = \(rawValue)"]
        return doc.render()
    }

    // MARK: Helpers

    private static func path(_ section: String) -> [String] {
        section.isEmpty ? [] : (TOMLDocument.parseKey(section) ?? [section])
    }

    private static func quoteKeyPart(_ part: String) -> String {
        TOMLDocument.parseKey(part) == [part] ? part : "\"\(part)\""
    }

    /// Index of the entry defining `section.key` (as `[section] key = …` or a dotted key), last one wins.
    private static func find(_ key: String, section: String, in doc: TOMLDocument) -> Int? {
        let target = path(section) + [key]
        return doc.entries.lastIndex { e in
            if case .keyValue(_, let k, _) = e.kind { return e.table + k == target }
            return false
        }
    }
}
