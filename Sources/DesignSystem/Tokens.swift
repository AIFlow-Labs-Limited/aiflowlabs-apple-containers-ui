import AppKit
import ContainerKit
// DesignSystem — tokens and reusable SwiftUI components for Container Desktop.
// Owned by the "shell" workstream; see docs/ARCHITECTURE.md § DesignSystem.
import SwiftUI

/// Namespace + version marker for the design system.
public enum DesignSystem {
    public static let version = "0.2.0"
}

/// Spacing scale (points). Use these instead of literals so density changes stay global.
public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
}

/// Corner radii.
public enum Radius {
    public static let small: CGFloat = 4
    public static let medium: CGFloat = 8
    public static let large: CGFloat = 12
}

// Semantic status colors, mapped to system colors so they adapt to light/dark and accessibility settings.
public extension ShapeStyle where Self == Color {
    /// Running / healthy.
    static var statusRunning: Color { Color(nsColor: .systemGreen) }
    /// Stopped / idle.
    static var statusStopped: Color { Color(nsColor: .systemGray) }
    /// Transitional or needs attention.
    static var statusWarning: Color { Color(nsColor: .systemOrange) }
    /// Failed.
    static var statusError: Color { Color(nsColor: .systemRed) }
}

public extension Font {
    /// Monospaced caption for ids, digests, log lines.
    static var monoCaption: Font { .caption.monospaced() }
    /// Monospaced body for editors and terminals-in-text.
    static var monoBody: Font { .body.monospaced() }
}

public extension ContainerState {
    /// Semantic color for this lifecycle state.
    var statusColor: Color {
        switch self {
        case .running: return .statusRunning
        case .stopped: return .statusStopped
        case .stopping, .created: return .statusWarning
        case .unknown: return .statusError
        }
    }

    /// Human label ("Running", "Exited", …) in Docker Desktop vocabulary.
    var displayName: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Exited"
        case .stopping: return "Stopping"
        case .created: return "Created"
        case .unknown: return "Unknown"
        }
    }
}

public extension BackendError {
    /// The exact CLI command that failed, when known. Contains secrets verbatim — display `maskedFailedCommand`.
    var failedCommand: String? {
        switch self {
        case .commandFailed(let command, _, _), .decoding(let command, _): return command
        default: return nil
        }
    }

    /// `failedCommand` safe to show and copy: every `-e`/`--env` value becomes `KEY=…` and passwords in
    /// `scheme://user:pass@` URLs become `••••`. (Masks all env values: DesignSystem cannot see AppCore's
    /// key-based detector, and the failing command is never meant to be re-run verbatim.)
    var maskedFailedCommand: String? { failedCommand.map(Self.maskSecrets(inCommand:)) }

    static func maskSecrets(inCommand command: String) -> String {
        let flag = #"(\s(?:-e|--env)(?:\s+|=))"#
        var masked = command
        // -e 'KEY=…'
        masked = masked.replacing(try! Regex(flag + #"'([^'=\s]+)=[^']*'"#)) { m in
            "\(m[1].substring ?? "")'\(m[2].substring ?? "")=…'"
        }
        // -e "KEY=…"
        masked = masked.replacing(try! Regex(flag + #""([^"=\s]+)=(?:[^"\\]|\\.)*""#)) { m in
            "\(m[1].substring ?? "")\"\(m[2].substring ?? "")=…\""
        }
        // -e KEY=value / -e KEY='quoted value'
        masked = masked.replacing(try! Regex(flag + #"([^\s'"=]+)=(?:'[^']*'|"[^"]*"|[^\s'"])+"#)) { m in
            "\(m[1].substring ?? "")\(m[2].substring ?? "")=…"
        }
        masked = masked.replacing(/([A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\/\s:@]*:)[^\/\s@]+@/) { m in "\(m.output.1)••••@" }
        return masked
    }

    /// Short title for banners and alerts.
    var title: String {
        switch self {
        case .systemNotRunning: return "Container system not running"
        case .cliNotInstalled: return "container is not installed"
        case .commandFailed: return "Command failed"
        case .notFound: return "Not found"
        case .decoding: return "Unexpected output"
        case .unsupported: return "Not supported"
        case .cancelled: return "Cancelled"
        case .permissionDenied: return "Permission denied"
        case .other: return "Something went wrong"
        }
    }
}

/// Copies text to the general pasteboard.
@MainActor
public func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
