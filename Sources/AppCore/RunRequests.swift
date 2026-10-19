import Foundation
import Observation
import ContainerKit

/// Hand-off from other sections ("Run" on an image, a build result…) to the Containers section's run sheet.
///
/// Producers call `request(_:)` (usually together with `navigation.open(.containers)`); the Containers view
/// observes `pending` and calls `consume()` when it presents its `RunContainerSheet(prefill:)`.
@MainActor
@Observable
public final class RunRequests {
    /// The spec waiting to be shown in the run sheet. `nil` when nothing is pending.
    public var pending: RunSpec?

    public init() {}

    /// Queues `spec` for the run sheet (replaces any earlier unconsumed request).
    public func request(_ spec: RunSpec) { pending = spec }

    /// Convenience: queue a run of `image` with default settings.
    public func request(image: String) { request(RunSpec(image: image)) }

    /// Returns and clears the pending spec.
    public func consume() -> RunSpec? {
        defer { pending = nil }
        return pending
    }
}
