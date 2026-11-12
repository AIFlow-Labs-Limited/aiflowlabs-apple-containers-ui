import Foundation

/// What a process needs to take part in shared supervision: the state file and its claim on enforcement.
@MainActor
public struct SupervisionSharing {
    /// The stops and engine stops the user asked for.
    public let state: any SupervisionStateStore
    /// This process's claim on being the enforcer.
    public let claim: EnforcementClaim

    /// Shares `state` and `claim`.
    public init(state: any SupervisionStateStore, claim: EnforcementClaim) {
        self.state = state
        self.claim = claim
    }

    /// The app's side, on the standard files. Stops recorded by an earlier version in `defaults` are carried
    /// over the first time.
    public static func app(adopting defaults: UserDefaults, paths: SupervisionPaths = .standard) -> SupervisionSharing {
        let state = FileSupervisionState(url: paths.state)
        state.adoptStops(from: defaults)
        return SupervisionSharing(state: state, claim: EnforcementClaim(role: .app, paths: paths))
    }

    /// The background helper's side, on the standard files.
    public static func helper(paths: SupervisionPaths = .standard) -> SupervisionSharing {
        SupervisionSharing(
            state: FileSupervisionState(url: paths.state), claim: EnforcementClaim(role: .helper, paths: paths))
    }
}
