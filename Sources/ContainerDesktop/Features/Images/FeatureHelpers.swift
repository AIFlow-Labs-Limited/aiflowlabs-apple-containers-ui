import SwiftUI
import AppCore

// Small helpers shared by the Images / Volumes / Networks / Builds / Machines / Kubernetes / Registries features.

extension Binding where Value: Collection, Value: ExpressibleByArrayLiteral, Value: Sendable {
    /// `true` while the collection is non-empty; setting `false` empties it. Drives confirmation dialogs from a
    /// "pending" list (`isPresented: $pendingDelete.isPresent`).
    var isPresent: Binding<Bool> {
        Binding<Bool>(get: { !wrappedValue.isEmpty }, set: { if !$0 { wrappedValue = [] } })
    }
}

/// `“a”, “b”` — quoted names for confirmation dialogs.
func listed(_ names: [String]) -> String { names.map { "“\($0)”" }.joined(separator: ", ") }

/// Copy for prune confirmations and the outcome toast.
enum PruneText {
    static func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    static func title(count: Int, noun: String) -> String { "Prune \(plural(count, "unused " + noun))?" }

    /// Names the candidates and says when some are hidden by the current search, because prune ignores it.
    static func message(candidates: [String], visible: [String], noun: String) -> String {
        let hidden = PruneCandidates.hiddenCount(candidates: candidates, visible: visible)
        let names = candidates.count <= 8 ? candidates.joined(separator: ", ")
                                          : candidates.prefix(8).joined(separator: ", ") + " and \(candidates.count - 8) more"
        let scope = hidden > 0 ? " (including \(hidden) hidden by your search)" : ""
        return "Permanently deletes \(plural(candidates.count, "unused " + noun))\(scope): \(names)."
    }

    /// Reports what really went away (before/after diff of the store), not the pre-computed estimate.
    @MainActor
    static func toast(_ toasts: ToastCenter, removed: [String], noun: String) {
        if removed.isEmpty {
            toasts.info("Nothing pruned", message: "No unused \(noun)s were removed.")
        } else {
            toasts.success("Pruned \(plural(removed.count, noun))", message: removed.prefix(5).joined(separator: ", ")
                           + (removed.count > 5 ? " and \(removed.count - 5) more" : ""))
        }
    }
}
