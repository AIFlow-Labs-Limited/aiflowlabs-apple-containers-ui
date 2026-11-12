import Foundation

/// Compose variable interpolation: `$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:?error}`,
/// `${VAR?error}`, `${VAR:+replacement}`, `${VAR+replacement}` and `$$` for a literal dollar sign. Defaults and
/// replacements may themselves contain variables.
public enum ComposeInterpolation {
    /// A variable a compose file refers to, for the preview's "Variables" table.
    public struct Reference: Hashable, Sendable, Identifiable {
        /// Variable name.
        public var name: String
        /// The `:-` / `-` default as written, when the file gives one.
        public var defaultValue: String?
        /// Whether the file marks it `:?` / `?` (the import fails without a value).
        public var isRequired: Bool

        public var id: String { name }

        /// A reference to `name`.
        public init(name: String, defaultValue: String? = nil, isRequired: Bool = false) {
            self.name = name
            self.defaultValue = defaultValue
            self.isRequired = isRequired
        }
    }

    /// `text` with every variable replaced from `variables`.
    ///
    /// - Parameter unset: receives the names used with no value and no default (they become empty strings).
    /// - Throws: `ComposeError.requiredVariable` for `${VAR:?…}` / `${VAR?…}` without a value.
    public static func interpolate(
        _ text: String, variables: [String: String], unset: inout Set<String>
    ) throws -> String {
        guard text.contains("$") else { return text }
        var result = ""
        for token in tokenize(text) {
            switch token {
            case .literal(let literal): result += literal
            case .variable(let name, let op, let argument):
                let value = variables[name]
                let isSet = value != nil
                let isNonEmpty = !(value ?? "").isEmpty
                switch op {
                case .none:
                    if !isSet { unset.insert(name) }
                    result += value ?? ""
                case .defaultIfEmpty:
                    result +=
                        isNonEmpty ? value! : try interpolate(argument, variables: variables, unset: &unset)
                case .defaultIfUnset:
                    result += isSet ? value! : try interpolate(argument, variables: variables, unset: &unset)
                case .errorIfEmpty:
                    guard isNonEmpty else { throw ComposeError.requiredVariable(name: name, message: argument) }
                    result += value!
                case .errorIfUnset:
                    guard isSet else { throw ComposeError.requiredVariable(name: name, message: argument) }
                    result += value!
                case .replacementIfNonEmpty:
                    if isNonEmpty { result += try interpolate(argument, variables: variables, unset: &unset) }
                case .replacementIfSet:
                    if isSet { result += try interpolate(argument, variables: variables, unset: &unset) }
                }
            }
        }
        return result
    }

    /// Convenience for callers that do not care which variables were unset.
    public static func interpolate(_ text: String, variables: [String: String]) throws -> String {
        var unset = Set<String>()
        return try interpolate(text, variables: variables, unset: &unset)
    }

    /// Variables `text` refers to, in order of first appearance (nested ones inside defaults included).
    public static func references(in text: String) -> [Reference] {
        var result: [Reference] = []
        collect(text, into: &result)
        return result
    }

    static func collect(_ text: String, into result: inout [Reference]) {
        guard text.contains("$") else { return }
        for token in tokenize(text) {
            guard case .variable(let name, let op, let argument) = token else { continue }
            let isDefault = op == .defaultIfEmpty || op == .defaultIfUnset
            let isRequired = op == .errorIfEmpty || op == .errorIfUnset
            if let index = result.firstIndex(where: { $0.name == name }) {
                if result[index].defaultValue == nil, isDefault { result[index].defaultValue = argument }
                if isRequired { result[index].isRequired = true }
            } else {
                result.append(
                    Reference(name: name, defaultValue: isDefault ? argument : nil, isRequired: isRequired))
            }
            if !isRequired { collect(argument, into: &result) }
        }
    }

    // MARK: Tokenizer

    enum Operator: Hashable {
        case none, defaultIfEmpty, defaultIfUnset, errorIfEmpty, errorIfUnset, replacementIfNonEmpty, replacementIfSet
    }

    enum Token: Hashable {
        case literal(String)
        case variable(name: String, op: Operator, argument: String)
    }

    private static func isNameStart(_ c: Character) -> Bool { c == "_" || (c.isASCII && c.isLetter) }
    private static func isNameBody(_ c: Character) -> Bool { c == "_" || (c.isASCII && (c.isLetter || c.isNumber)) }

    /// Splits `text` into literals and variable references. Anything that is not a well-formed reference
    /// (`$5`, `${`, `${1x}`) is kept as literal text rather than rejected.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var literal = ""
        let chars = Array(text)
        var i = 0
        func flush() {
            if !literal.isEmpty { tokens.append(.literal(literal)); literal = "" }
        }
        while i < chars.count {
            guard chars[i] == "$", i + 1 < chars.count else {
                literal.append(chars[i]); i += 1
                continue
            }
            let next = chars[i + 1]
            if next == "$" {
                literal.append("$"); i += 2
            } else if next == "{", let (token, end) = braced(chars, from: i + 2) {
                flush()
                tokens.append(token)
                i = end
            } else if isNameStart(next) {
                var j = i + 1
                while j < chars.count, isNameBody(chars[j]) { j += 1 }
                flush()
                tokens.append(.variable(name: String(chars[(i + 1)..<j]), op: .none, argument: ""))
                i = j
            } else {
                literal.append("$"); i += 1
            }
        }
        flush()
        return tokens
    }

    /// Parses `NAME[op argument]}` starting just after `${`. Returns the token and the index after the `}`.
    private static func braced(_ chars: [Character], from start: Int) -> (Token, Int)? {
        guard start < chars.count, isNameStart(chars[start]) else { return nil }
        var j = start
        while j < chars.count, isNameBody(chars[j]) { j += 1 }
        let name = String(chars[start..<j])
        guard j < chars.count else { return nil }
        if chars[j] == "}" { return (.variable(name: name, op: .none, argument: ""), j + 1) }
        let op: Operator
        let two = j + 1 < chars.count ? String(chars[j...(j + 1)]) : ""
        switch (two, chars[j]) {
        case (":-", _): op = .defaultIfEmpty; j += 2
        case (":?", _): op = .errorIfEmpty; j += 2
        case (":+", _): op = .replacementIfNonEmpty; j += 2
        case (_, "-"): op = .defaultIfUnset; j += 1
        case (_, "?"): op = .errorIfUnset; j += 1
        case (_, "+"): op = .replacementIfSet; j += 1
        default: return nil
        }
        // The argument runs to the matching `}`; nested `${…}` may contain braces of their own.
        var depth = 0
        var k = j
        while k < chars.count {
            if chars[k] == "$", k + 1 < chars.count, chars[k + 1] == "{" {
                depth += 1; k += 2
                continue
            }
            if chars[k] == "}" {
                if depth == 0 { return (.variable(name: name, op: op, argument: String(chars[j..<k])), k + 1) }
                depth -= 1
            }
            k += 1
        }
        return nil
    }
}
