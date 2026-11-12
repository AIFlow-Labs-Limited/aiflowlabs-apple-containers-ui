import Foundation

/// The range of Apple `container` versions this app supports. This is the ONE place the range is defined;
/// the Updates pane, the status bar notice and the Homebrew cask caveat wording all follow it.
public enum RuntimeSupport {
    /// Oldest `container` release the app works with. Older CLIs lack JSON output the app decodes.
    public static let minimum = SemanticVersion(1, 5, 0)
    /// Newest `container` release the app has been tested against. 1.5.0 and 1.7.1 were run on a live engine
    /// (2026-11-12); 1.6.x in between is supported from source only. See `docs/COMPATIBILITY.md`.
    public static let testedUpTo = SemanticVersion(1, 7, 1)

    /// How an installed runtime version relates to the supported range.
    public enum Compatibility: Equatable, Sendable {
        /// The installed version is not known (engine stopped, CLI missing, or an unparseable version).
        case unknown
        /// Within `minimum...testedUpTo`.
        case supported
        /// Older than `minimum`: features will break.
        case tooOld(installed: SemanticVersion)
        /// Newer than `testedUpTo`: should work, but is untested.
        case newerThanTested(installed: SemanticVersion)
    }

    /// `1.5.0 to 1.7.1`.
    public static var rangeDescription: String { "\(minimum) to \(testedUpTo)" }

    /// Classifies the installed runtime version (the string the CLI reports, e.g. `1.6.0`).
    public static func compatibility(of installed: String?) -> Compatibility {
        guard let installed, let version = SemanticVersion(installed) else { return .unknown }
        if version < minimum { return .tooOld(installed: version) }
        if version > testedUpTo { return .newerThanTested(installed: version) }
        return .supported
    }

    /// A calm, one-sentence notice for an out-of-range runtime; `nil` when supported or unknown.
    public static func notice(for compatibility: Compatibility) -> String? {
        switch compatibility {
        case .unknown, .supported:
            return nil
        case .tooOld(let installed):
            return "container \(installed) is older than \(minimum), the oldest version Container Desktop supports. "
                + "Some features will not work until the runtime is upgraded."
        case .newerThanTested(let installed):
            return "container \(installed) is newer than \(testedUpTo), the latest version Container Desktop was "
                + "tested with. It should work; please report anything that does not."
        }
    }
}
