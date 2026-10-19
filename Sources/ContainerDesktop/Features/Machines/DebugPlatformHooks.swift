#if DEBUG
import SwiftUI
import Observation

/// DEBUG-only requests from `DebugLaunchActions` (e.g. `machine-create`) that the platform views pick up to open
/// their sheets for screenshots. Observable so a request that arrives after the view appeared still fires.
@MainActor
@Observable
final class DebugPlatformHooks {
    static let shared = DebugPlatformHooks()
    private(set) var pending: Set<String> = []

    static func request(_ token: String) { shared.pending.insert(token) }

    /// Returns `true` once per requested token.
    static func consume(_ token: String) -> Bool { shared.pending.remove(token) != nil }
}

extension View {
    /// Runs `action` when the DEBUG hook `token` is requested (now or later).
    func debugHook(_ token: String, perform action: @escaping () -> Void) -> some View {
        onChange(of: DebugPlatformHooks.shared.pending, initial: true) {
            if DebugPlatformHooks.consume(token) { action() }
        }
    }
}
#endif
