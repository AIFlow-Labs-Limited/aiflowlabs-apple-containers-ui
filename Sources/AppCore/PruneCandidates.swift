import ContainerKit
import Foundation

/// What a prune is expected to remove. `container volume|network|image prune` ignores the UI's search field, so
/// candidates are always computed from the store's full `items`, never from `filtered`.
public enum PruneCandidates {
    /// Volumes no container mounts.
    public static func volumes(_ volumes: [Volume], containers: [Container]) -> [Volume] {
        volumes.filter { ResourceUsage.containers(mounting: $0, in: containers).isEmpty }
    }

    /// Non-built-in networks no container is attached to.
    public static func networks(_ networks: [Network], containers: [Container]) -> [Network] {
        networks.filter { !$0.isBuiltin && ResourceUsage.containers(attachedTo: $0, in: containers).isEmpty }
    }

    /// Images no container uses; with `all == false` only untagged (dangling) ones.
    public static func images(_ images: [Image], containers: [Container], all: Bool) -> [Image] {
        images.filter {
            ResourceUsage.containers(using: $0, in: containers).isEmpty && (all || ResourceUsage.isUntagged($0))
        }
    }

    /// How many candidates the current search hides.
    public static func hiddenCount(candidates: [String], visible: [String]) -> Int {
        let shown = Set(visible)
        return candidates.count { !shown.contains($0) }
    }

    /// What actually went away: ids present before the prune and missing after (order kept).
    public static func removed(before: [String], after: [String]) -> [String] {
        let remaining = Set(after)
        return before.filter { !remaining.contains($0) }
    }
}
