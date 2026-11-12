import Foundation

/// Keeps command-line arguments and environment values byte-exact when they are handed to a child process.
///
/// Foundation's `Process` passes arguments and environment values through the file-system representation,
/// which decomposes Unicode: `é` (C3 A9) arrives as `e` + combining accent (65 CC 81), Hangul syllables as
/// jamo. A container then gets an environment value, command or path that differs from what the user typed.
/// When a launch contains such text, it is routed through `/bin/sh` with an ASCII-only script that rebuilds
/// the exact bytes with `printf` and `exec`s the real program, so the pid, process group, pipes and exit
/// status are those of the real program. Launches without such text are not touched.
enum ByteExactLaunch {
    /// The shell used as trampoline.
    static let shell = "/bin/sh"

    /// A rewritten launch: `arguments[0]` is the shell.
    struct Launch: Equatable {
        var arguments: [String]
        var environment: [String: String]
    }

    /// Whether `Process` would alter `text` on the way to the child.
    static func isAltered(_ text: String) -> Bool {
        guard !text.utf8.allSatisfy({ $0 < 0x80 }) else { return false }
        return !text.utf8.elementsEqual(text.decomposedStringWithCanonicalMapping.utf8)
    }

    /// The trampoline launch for `arguments` and `environment`, or `nil` when nothing in them would be altered.
    static func rewrite(arguments: [String], environment: [String: String]) -> Launch? {
        let alteredVariables = environment.filter { isAltered($0.value) && isShellName($0.key) }.keys.sorted()
        guard arguments.contains(where: isAltered) || !alteredVariables.isEmpty else { return nil }

        var script = ""
        var passedEnvironment = environment
        for (index, name) in alteredVariables.enumerated() {
            let variable = "e\(index)"
            script += assignment(variable, environment[name] ?? "") + "export \(name)=\"$\(variable)\"; "
            passedEnvironment[name] = nil
        }

        var positional: [String] = []
        var words: [String] = []
        for (index, argument) in arguments.enumerated() {
            if isAltered(argument) {
                let variable = "a\(index)"
                script += assignment(variable, argument)
                words.append("\"$\(variable)\"")
            } else {
                positional.append(argument)
                words.append("\"${\(positional.count)}\"")
            }
        }
        script += "exec " + words.joined(separator: " ")
        return Launch(arguments: [shell, "-c", script, "sh"] + positional, environment: passedEnvironment)
    }

    /// `v=$(printf '<octal bytes>x'); v=${v%x}; `. The trailing `x` protects trailing newlines from `$(…)`.
    private static func assignment(_ variable: String, _ value: String) -> String {
        let octal = value.utf8.map { "\\" + String($0, radix: 8) }.joined()
        return "\(variable)=$(printf '\(octal)x'); \(variable)=${\(variable)%x}; "
    }

    /// Whether `name` can be used with `export NAME=` (other names keep going through `Process`).
    private static func isShellName(_ name: String) -> Bool {
        guard let first = name.utf8.first, first == UInt8(ascii: "_") || isLetter(first) else { return false }
        return name.utf8.allSatisfy { $0 == UInt8(ascii: "_") || isLetter($0) || (0x30...0x39).contains($0) }
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}
