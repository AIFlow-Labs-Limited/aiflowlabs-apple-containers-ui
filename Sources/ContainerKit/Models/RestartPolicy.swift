import Foundation

/// A Docker-style restart policy. Apple's runtime has none (CLI 1.5.0 has no `--restart`), so Container Desktop
/// stores the policy as the label `AppLabel.restart` on the container and enforces it itself while it is running.
public enum RestartPolicy: Hashable, Sendable {
    /// Never restarted (the default; no label is written).
    case no
    /// Restarted whenever it stops, and started when the app launches or the engine comes up.
    case always
    /// Like `always`, except that a container stopped from the app stays stopped until it is started again.
    case unlessStopped
    /// Restarted when it stops unexpectedly, at most `maxRetries` times in a row (`nil` = no limit).
    case onFailure(maxRetries: Int?)

    /// Parses Docker's spelling: `no`, `always`, `unless-stopped`, `on-failure`, `on-failure:5`.
    /// Returns `nil` for anything else (including `on-failure:0` or a negative count).
    public init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch value {
        case "no", "": self = .no
        case "always": self = .always
        case "unless-stopped": self = .unlessStopped
        case "on-failure": self = .onFailure(maxRetries: nil)
        default:
            guard value.hasPrefix("on-failure:"), let count = Int(value.dropFirst("on-failure:".count)), count > 0
            else { return nil }
            self = .onFailure(maxRetries: count)
        }
    }

    /// Docker's spelling, which is also the label value (`on-failure:5`).
    public var rawValue: String {
        switch self {
        case .no: return "no"
        case .always: return "always"
        case .unlessStopped: return "unless-stopped"
        case .onFailure(let maxRetries): return maxRetries.map { "on-failure:\($0)" } ?? "on-failure"
        }
    }

    /// Value for the `AppLabel.restart` label; `nil` for `.no`, which is stored as "no label".
    public var labelValue: String? { self == .no ? nil : rawValue }

    /// Whether the policy ever restarts anything.
    public var isEnforced: Bool { self != .no }

    /// Whether a stopped container with this policy is started when the app launches or the engine comes up.
    /// `intentionallyStopped` is whether it was last stopped from the app.
    public func startsOnLaunch(intentionallyStopped: Bool) -> Bool {
        switch self {
        case .always: return true
        case .unlessStopped: return !intentionallyStopped
        case .no, .onFailure: return false
        }
    }

    /// One line for the UI: what the policy does, in the app's terms.
    public var summary: String {
        switch self {
        case .no: return "Not restarted."
        case .always:
            return "Started again whenever it stops, and when Container Desktop or the engine starts."
        case .unlessStopped:
            return "Started again when it stops on its own. Stays stopped after you stop it here."
        case .onFailure(let maxRetries):
            let limit = maxRetries.map { ", at most \($0) time\($0 == 1 ? "" : "s") in a row" } ?? ""
            return "Started again when it stops on its own\(limit). Not started when the app launches."
        }
    }
}

extension Container {
    /// The restart policy stored in the `AppLabel.restart` label (`.no` when there is no label or it is unreadable).
    public var restartPolicy: RestartPolicy { labels[AppLabel.restart].flatMap { RestartPolicy($0) } ?? .no }
}
