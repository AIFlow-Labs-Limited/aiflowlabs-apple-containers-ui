import Foundation

/// A problem found by `TOMLValidator`.
public struct TOMLIssue: Hashable, Sendable {
    public var line: Int
    public var message: String
    public init(line: Int, message: String) { self.line = line; self.message = message }
}

/// Tiny structural validator for `config.toml` — not a TOML parser. Catches what users typically break when
/// hand-editing: unbalanced `[section]` headers, lines that are not `key = value`, unterminated strings/arrays,
/// duplicate sections. No dependency on a TOML library by design.
public enum TOMLValidator {
    public static func validate(_ text: String) -> [TOMLIssue] {
        var issues: [TOMLIssue] = []
        var sections = Set<String>()
        var keysInSection = Set<String>()
        var openArrayDepth = 0
        var openArrayLine = 0
        var inMultilineString = false
        var multilineStart = 0

        for (offset, rawLine) in text.components(separatedBy: "\n").enumerated() {
            let number = offset + 1
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)

            if inMultilineString {
                if line.contains("\"\"\"") { inMultilineString = false }
                continue
            }
            if openArrayDepth > 0 {
                openArrayDepth += bracketDelta(line)
                continue
            }
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                let isArrayTable = line.hasPrefix("[[")
                let close = isArrayTable ? "]]" : "]"
                guard line.hasSuffix(close) else {
                    issues.append(TOMLIssue(line: number, message: "Section header is missing “\(close)”"))
                    continue
                }
                let name = line.dropFirst(isArrayTable ? 2 : 1).dropLast(isArrayTable ? 2 : 1).trimmingCharacters(in: .whitespaces)
                if name.isEmpty || name.contains("[") || name.contains("]") || !isValidKey(name) {
                    issues.append(TOMLIssue(line: number, message: "Invalid section name “\(name)”"))
                    continue
                }
                if !isArrayTable {
                    if sections.contains(name) { issues.append(TOMLIssue(line: number, message: "Duplicate section [\(name)]")) }
                    sections.insert(name)
                }
                keysInSection = []
                continue
            }

            guard let eq = line.firstIndex(of: "=") else {
                issues.append(TOMLIssue(line: number, message: "Expected “key = value”"))
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if key.isEmpty || !isValidKey(key) {
                issues.append(TOMLIssue(line: number, message: "Invalid key “\(key)”"))
                continue
            }
            if value.isEmpty {
                issues.append(TOMLIssue(line: number, message: "Missing value for “\(key)”"))
                continue
            }
            if keysInSection.contains(key) { issues.append(TOMLIssue(line: number, message: "Duplicate key “\(key)”")) }
            keysInSection.insert(key)

            if value.hasPrefix("\"\"\"") {
                if value.count < 6 || !value.dropFirst(3).contains("\"\"\"") { inMultilineString = true; multilineStart = number }
                continue
            }
            if value.hasPrefix("\"") && !(value.count >= 2 && value.hasSuffix("\"")) {
                issues.append(TOMLIssue(line: number, message: "Unterminated string"))
                continue
            }
            if value.hasPrefix("'") && !(value.count >= 2 && value.hasSuffix("'")) {
                issues.append(TOMLIssue(line: number, message: "Unterminated string"))
                continue
            }
            if value.hasPrefix("[") {
                let delta = bracketDelta(value)
                if delta > 0 { openArrayDepth = delta; openArrayLine = number }
            }
        }
        if inMultilineString { issues.append(TOMLIssue(line: multilineStart, message: "Unterminated multi-line string")) }
        if openArrayDepth > 0 { issues.append(TOMLIssue(line: openArrayLine, message: "Unterminated array")) }
        return issues
    }

    static func isValidKey(_ key: String) -> Bool {
        if key.hasPrefix("\"") { return key.count >= 2 && key.hasSuffix("\"") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-. "))
        return key.unicodeScalars.allSatisfy { allowed.contains($0) } && !key.hasPrefix(".") && !key.hasSuffix(".")
    }

    /// Drops a trailing `# comment` that is outside quotes.
    static func stripComment(_ line: String) -> String {
        var inString: Character?
        for (i, ch) in zip(line.indices, line) {
            if let q = inString { if ch == q { inString = nil } }
            else if ch == "\"" || ch == "'" { inString = ch }
            else if ch == "#" { return String(line[..<i]) }
        }
        return line
    }

    static func bracketDelta(_ s: String) -> Int {
        var depth = 0
        var inString: Character?
        for ch in s {
            if let q = inString { if ch == q { inString = nil }; continue }
            switch ch {
            case "\"", "'": inString = ch
            case "[": depth += 1
            case "]": depth -= 1
            default: break
            }
        }
        return depth
    }
}

/// Line-based edits of simple `key = value` pairs, preserving comments and formatting elsewhere.
/// Used by Settings → Resources to set `[container] cpus = 4` etc.
public enum TOMLEditor {
    /// Raw value text (`4`, `"8g"`) of `key` in `[section]`, or nil.
    public static func value(_ key: String, section: String, in text: String) -> String? {
        var current = ""
        for raw in text.components(separatedBy: "\n") {
            let line = TOMLValidator.stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && !line.hasPrefix("[[") { current = sectionName(line); continue }
            guard current == section, let eq = line.firstIndex(of: "=") else { continue }
            if line[..<eq].trimmingCharacters(in: .whitespaces) == key {
                return line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Unquoted string value.
    public static func stringValue(_ key: String, section: String, in text: String) -> String? {
        value(key, section: section, in: text).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
    }

    /// Sets (or with `nil` removes) `key = rawValue` in `[section]`, creating the section when needed.
    public static func setting(_ key: String, to rawValue: String?, section: String, in text: String) -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        var current = ""
        var sectionHeader: Int?
        var sectionEnd: Int?
        for (i, raw) in lines.enumerated() {
            let line = TOMLValidator.stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if current == section && sectionEnd == nil && sectionHeader != nil { sectionEnd = i }
                current = line.hasPrefix("[[") ? "" : sectionName(line)
                if current == section { sectionHeader = i }
                continue
            }
            guard current == section, let eq = line.firstIndex(of: "="),
                  line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            if let rawValue { lines[i] = "\(key) = \(rawValue)" } else { lines.remove(at: i) }
            return lines.joined(separator: "\n")
        }
        guard let rawValue else { return text }
        if let header = sectionHeader {
            var insertAt = sectionEnd ?? lines.count
            while insertAt > header + 1 && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            lines.insert("\(key) = \(rawValue)", at: insertAt)
        } else {
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines += ["[\(section)]", "\(key) = \(rawValue)"]
        }
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    private static func sectionName(_ line: String) -> String {
        line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).trimmingCharacters(in: .whitespaces)
    }
}
