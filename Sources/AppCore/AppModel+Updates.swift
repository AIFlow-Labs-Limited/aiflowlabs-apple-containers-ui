import ContainerKit
import Foundation

/// What the update UI needs that combines the engine state with `UpdateChecker`.
public extension AppModel {
    /// The installed `container` CLI version as the engine reports it (`system status` → client), or `nil`
    /// while the engine is not running or the CLI is missing.
    var installedRuntimeVersion: String? {
        engine.status?.client?.version ?? system.status?.client?.version
    }

    /// How the installed runtime relates to `RuntimeSupport`'s range.
    var runtimeCompatibility: RuntimeSupport.Compatibility {
        RuntimeSupport.compatibility(of: installedRuntimeVersion)
    }

    /// The runtime release to offer, if a newer stable one is known.
    var runtimeUpdate: ReleaseInfo? { updates.runtimeUpdate(installed: installedRuntimeVersion) }

    /// True when a newer app or runtime release is known (drives the status bar and menu bar indicators).
    var isUpdateAvailable: Bool { updates.appUpdate != nil || runtimeUpdate != nil }

    /// One line for the indicator's tooltip and the menu bar item, e.g.
    /// `Container Desktop 0.2.0 and container 1.7.1 are available`. `nil` when nothing is on offer.
    var updateSummary: String? {
        var names: [String] = []
        if let app = updates.appUpdate { names.append("Container Desktop \(app.version)") }
        if let runtime = runtimeUpdate { names.append("container \(runtime.version)") }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: " and ") + (names.count == 1 ? " is available" : " are available")
    }
}
