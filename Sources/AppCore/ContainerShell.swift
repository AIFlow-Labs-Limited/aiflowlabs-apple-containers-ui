import Foundation

/// Validation for the Terminal tab's custom shell field. Quoting for the Terminal.app hand-off uses
/// `ContainerKit.ShellQuote` (the app's single quoter).
public enum ContainerShell {
    /// Shell names accepted without a path (resolved inside the container's PATH).
    public static let knownShells: Set<String> = [
        "sh", "ash", "bash", "dash", "zsh", "fish", "ksh", "mksh", "tcsh", "csh", "busybox",
    ]

    /// `nil` when `text` is a usable custom shell: one word, no shell metacharacters, either an absolute path
    /// or a known shell name. Otherwise a user-facing reason.
    public static func validationError(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Enter a shell, e.g. /bin/ash." }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "'\"$`\\|&;<>()*?[]{}!#~=%^,"))
        if t.rangeOfCharacter(from: forbidden) != nil {
            return "Use a single shell path without spaces or special characters."
        }
        if t.hasPrefix("/") {
            return t.contains("/../") || t.hasSuffix("/") ? "“\(t)” is not a valid shell path." : nil
        }
        return knownShells.contains(t)
            ? nil : "Use an absolute path (e.g. /bin/ash) or one of: \(knownShells.sorted().joined(separator: ", "))."
    }
}
