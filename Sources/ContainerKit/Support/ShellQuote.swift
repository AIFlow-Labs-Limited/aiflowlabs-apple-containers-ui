import Foundation

/// POSIX `sh` quoting for "copy as command" and diagnostics.
///
/// A word made only of `[A-Za-z0-9-_./:=@%+,]` is left bare; anything else (including the empty string) is
/// wrapped in single quotes, with embedded `'` written as `'\''`. The result is safe to paste into `sh`,
/// `bash` and `zsh`: no globbing, expansion, history (`!`) or command separators survive.
public enum ShellQuote {
    private static let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./:=@%+,")

    /// One shell word.
    public static func quote(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ safe.contains($0) }) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Words joined by single spaces, each quoted as needed.
    public static func join(_ words: [String]) -> String {
        words.map(quote).joined(separator: " ")
    }
}
