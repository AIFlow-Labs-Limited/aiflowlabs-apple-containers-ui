import Foundation

/// Explains what the CLI prints when it cannot reach, or log in to, a registry.
///
/// The CLI's messages for these cases are short and technical (`-9836: bad protocol version`,
/// `POSIXErrorCode(rawValue: 61): Connection refused`), and most arrive only after about 40 seconds of retries.
/// The explanation says what to change; the CLI's own text follows in parentheses, so nothing is hidden.
///
/// "Seen" below means container 1.7.1 printed it against a local `registry:2` on 2026-11-12. The other wordings
/// were read from the 1.7.1 binary and have not been produced live.
enum RegistryFailure {
    /// What the user was doing.
    enum Action: Sendable { case login, push, pull }

    /// The registry host of an image reference (`localhost:5000/app:1` → `localhost:5000`), or `nil` when the
    /// reference names none and the CLI's default registry applies.
    static func host(ofReference reference: String) -> String? {
        let parts = reference.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let first = parts.first else { return nil }
        let isHost = first.contains(".") || first.contains(":") || first == "localhost" || first.hasPrefix("[")
        return isHost ? String(first) : nil
    }

    /// Rewrites a `.commandFailed` whose message is one of the known registry failures. Every other error is
    /// returned as it is.
    static func explain(_ error: any Error, host: String?, action: Action, platform: Platform? = nil) -> any Error {
        guard case BackendError.commandFailed(let command, let exitCode, let message) = error,
            let explanation = explanation(of: message, host: host, action: action, platform: platform)
        else { return error }
        return BackendError.commandFailed(command: command, exitCode: exitCode, message: explanation)
    }

    /// The message to show for the CLI's `message`, or `nil` when it is not a registry failure known here.
    static func explanation(of message: String, host: String?, action: Action, platform: Platform? = nil) -> String? {
        guard let advice = advice(for: message, registry: host ?? "The registry", action: action, platform: platform)
        else { return nil }
        return "\(advice) (\(lastLine(of: message)))"
    }

    private static func advice(for message: String, registry: String, action: Action, platform: Platform?) -> String? {
        let lower = message.lowercased()
        // Seen: `refusing insecure credential exchange: registry 127.0.0.1 issued an authentication challenge
        // over an insecure connection`, for login, push and pull alike.
        if lower.contains("insecure credential exchange") || lower.contains("over an insecure connection") {
            return "\(registry) asks for a login, and container does not send credentials over plain HTTP. "
                + (action == .login
                    ? "Log in over HTTPS. A registry without authentication needs no login to push or pull."
                    : "Use HTTPS for a registry that needs a login; plain HTTP only works without authentication.")
        }
        // Seen: `-9836: bad protocol version`, HTTPS spoken to a port that serves plain HTTP.
        if lower.contains("-9836") || lower.contains("bad protocol version") {
            return "\(registry) did not answer with HTTPS. If it serves plain HTTP (a local registry, for example), "
                + "choose HTTP as the connection and try again."
        }
        // Not seen live: the other Secure Transport codes (-9807 certificate chain, -9813 no root, -9843 host name).
        if message.firstMatch(of: #/(^|\s)-98\d\d:\s/#) != nil {
            return "The secure (HTTPS) connection to \(registry) could not be set up. Its certificate may not be "
                + "trusted by this Mac."
        }
        // Seen: `POSIXErrorCode(rawValue: 61): Connection refused`.
        if lower.contains("connection refused") {
            return "Nothing answers at \(registry) (connection refused). Check the host and port, and that the "
                + "registry is running."
        }
        // Seen: `failed to resolve either repository hostname <host>`.
        if lower.contains("failed to resolve") {
            return "The host \(registry) could not be found. Check the spelling and the network connection."
        }
        if lower.contains("posixerrorcode") {
            return "The connection to \(registry) failed. Check the host and port, and the network connection."
        }
        // Not seen live (needs a registry with a login over trusted HTTPS): `access denied or wrong credentials`.
        if lower.contains("access denied or wrong credentials") || lower.contains("unauthorized") {
            switch action {
            case .login:
                return "\(registry) did not accept the user name or password. Docker Hub and GitHub want an access "
                    + "token, not the account password."
            case .push:
                return "\(registry) refused the push. Log in under Registries, and check that the account may write "
                    + "to this repository."
            case .pull:
                return "\(registry) refused the pull. The image may be private (log in under Registries) or may not "
                    + "exist."
            }
        }
        // Seen: `content with digest sha256:…`, pushing every platform of an image pulled for this Mac only.
        if action == .push, platform == nil, lower.contains("content with digest") {
            return "Part of the image is not in the local image store: it lists platforms that were never downloaded, "
                + "so “All platforms” cannot be pushed. Choose a single platform (for example linux/arm64)."
        }
        return nil
    }

    /// The CLI's closing line, which carries the error (earlier lines repeat the progress of the retries).
    private static func lastLine(of message: String) -> String {
        message.split(whereSeparator: \.isNewline).last.map(String.init) ?? message
    }
}
