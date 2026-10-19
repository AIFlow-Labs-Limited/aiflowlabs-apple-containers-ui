import Foundation

/// Turns a failed `container` invocation into a `BackendError` with a human-readable message.
enum CLIErrorMapper {
    /// `true` for CLI progress lines such as `[3/6] Fetching kernel [0s]`.
    static func isProgressLine(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        guard trimmed.first == "[" else { return false }
        let inner = trimmed.dropFirst().prefix { $0 != "]" }
        let parts = inner.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            && trimmed.dropFirst(inner.count + 1).first == "]"
    }

    /// Strips ANSI codes, progress lines, blank lines and the `Error: ` prefix from CLI stderr.
    static func cleanMessage(_ stderr: String) -> String {
        let lines =
            stderr
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { LineSplitter.stripANSI(String($0)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isProgressLine($0) }
            .map { $0.hasPrefix("Error: ") ? String($0.dropFirst("Error: ".count)) : $0 }
        return lines.joined(separator: "\n")
    }

    /// The apiserver is definitely down (`container system status` and friends say so explicitly).
    static func indicatesSystemNotRunning(_ text: String) -> Bool {
        let lower = text.lowercased()
        // CLI 1.5.0 list/inspect commands with the engine stopped: `Error: interrupted: "XPC connection error:
        // Connection invalid"` + "Ensure container system service has been started with `container system start`."
        return lower.contains("apiserver is not running") || lower.contains("not registered with launchd")
            || lower.contains("ensure container system service has been started")
    }

    /// `Plugins are unavailable` is printed both when services are down and for a mistyped subcommand, so
    /// it only means `.systemNotRunning` once `container system status` has also failed.
    static func isPluginsUnavailable(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("Plugins are unavailable")
    }

    /// `osascript` reports "User canceled. (-128)" when the administrator prompt is dismissed. Only meaningful
    /// for `osascript` output (`CLIBackend.runAsAdministrator` checks it); `map` does not.
    static func indicatesUserCancelled(_ text: String) -> Bool {
        text.contains("(-128)") || text.localizedCaseInsensitiveContains("User canceled")
    }

    /// Extracts the resource kind and id from CLI "not found" errors, e.g.
    /// `Error: image not found: nope:1` or `… notFound: "container with ID web not found"`.
    static func notFound(in text: String) -> (kind: String, id: String)? {
        guard text.localizedCaseInsensitiveContains("not found") else { return nil }
        let quotes = CharacterSet(charactersIn: "\"'“”")
        if let match = text.firstMatch(of: /([A-Za-z]+(?: machine)?) with ID ([^\s"']+) not found/) {
            return (normalizeKind(String(match.1)), String(match.2).trimmingCharacters(in: quotes))
        }
        if let match = text.firstMatch(of: /([A-Za-z]+) not found: ([^\n]+)/) {
            return (normalizeKind(String(match.1)), String(match.2).trimmingCharacters(in: .whitespaces.union(quotes)))
        }
        return nil
    }

    private static func normalizeKind(_ raw: String) -> String {
        let kind = raw.lowercased()
        return kind == "container machine" ? "machine" : kind
    }

    /// Maps a non-zero exit to the most specific `BackendError`. The ambiguous `Plugins are unavailable`
    /// case maps to `.commandFailed`; `CLIBackend` upgrades it after probing `system status`.
    static func map(command: String, exitCode: Int32, stderr: String, stdout: String = "") -> BackendError {
        let raw = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? stdout : stderr
        if indicatesSystemNotRunning(raw) { return .systemNotRunning }
        if let (kind, id) = notFound(in: raw) { return .notFound(kind: kind, id: id) }
        return .commandFailed(command: command, exitCode: exitCode, message: cleanMessage(raw))
    }
}
