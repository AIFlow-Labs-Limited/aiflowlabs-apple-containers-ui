import Foundation
import Observation

/// What a palette entry does when chosen.
public enum PaletteAction: Hashable, Sendable {
    case navigate(SidebarSection, itemID: String?)
    case startEngine, stopEngine, cleanUp, openSettings, openActivity, refresh, toggleTerminal
}

/// One row of the command palette.
public struct PaletteItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var symbol: String
    public var action: PaletteAction

    public init(id: String, title: String, subtitle: String, symbol: String, action: PaletteAction) {
        self.id = id; self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.action = action
    }
}

/// `⌘K` model: builds items from the stores, fuzzy-matches the query, remembers recent picks.
@MainActor
@Observable
public final class CommandPalette {
    public var query = ""
    public private(set) var recents: [String] = []
    public static let maxRecents = 8
    public static let maxResults = 40

    public init() {}

    /// Static actions available everywhere.
    public static let actions: [PaletteItem] = [
        PaletteItem(
            id: "action.start-engine", title: "Start engine", subtitle: "container system start", symbol: "play.circle",
            action: .startEngine),
        PaletteItem(
            id: "action.stop-engine", title: "Stop engine", subtitle: "container system stop", symbol: "stop.circle",
            action: .stopEngine),
        PaletteItem(
            id: "action.prune", title: "Prune…", subtitle: "Clean up unused containers, images, volumes",
            symbol: "trash", action: .cleanUp),
        PaletteItem(
            id: "action.settings", title: "Open Settings", subtitle: "Preferences", symbol: "gearshape",
            action: .openSettings),
        PaletteItem(
            id: "action.activity", title: "Open Activity", subtitle: "Running and recent tasks",
            symbol: "list.bullet.rectangle", action: .openActivity),
        PaletteItem(
            id: "action.refresh", title: "Refresh", subtitle: "Reload the current section", symbol: "arrow.clockwise",
            action: .refresh),
        PaletteItem(
            id: "action.terminal", title: "Toggle terminal", subtitle: "Integrated terminal panel", symbol: "terminal",
            action: .toggleTerminal),
    ]

    /// All candidate items for the current model state.
    public func items(for model: AppModel) -> [PaletteItem] {
        var items = SidebarSection.allCases.map {
            PaletteItem(
                id: "section.\($0.rawValue)", title: $0.title, subtitle: "Go to section", symbol: $0.symbol,
                action: .navigate($0, itemID: nil))
        }
        items += model.containers.items.filter { !$0.isSystemManaged }.map {
            PaletteItem(
                id: "container.\($0.id)", title: $0.id, subtitle: "Container · \($0.imageReference)",
                symbol: "shippingbox",
                action: .navigate(.containers, itemID: $0.id))
        }
        items += model.images.items.map {
            PaletteItem(
                id: "image.\($0.id).\($0.reference)", title: $0.reference, subtitle: "Image · \($0.shortID)",
                symbol: "square.stack.3d.up",
                action: .navigate(.images, itemID: $0.id))
        }
        items += model.volumes.items.map {
            PaletteItem(
                id: "volume.\($0.name)", title: $0.name, subtitle: "Volume", symbol: "externaldrive",
                action: .navigate(.volumes, itemID: $0.name))
        }
        items += model.machines.items.map {
            PaletteItem(
                id: "machine.\($0.name)", title: $0.name, subtitle: "Machine", symbol: "desktopcomputer",
                action: .navigate(.machines, itemID: $0.name))
        }
        return items + Self.actions
    }

    /// Ranked matches for `query`; with an empty query, recents first then everything.
    public func results(in items: [PaletteItem]) -> [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let recent = recents.compactMap { byID[$0] }
            let rest = items.filter { !recents.contains($0.id) }
            return Array((recent + rest).prefix(Self.maxResults))
        }
        return
            items
            .compactMap { item -> (PaletteItem, Int)? in
                let candidates = [Self.score(q, item.title), Self.score(q, item.subtitle).map { $0 - 50 }].compactMap {
                    $0
                }
                guard let best = candidates.max() else { return nil }
                let recentBonus = recents.contains(item.id) ? 15 : 0
                return (item, best + recentBonus)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.count < $1.0.title.count }
            .prefix(Self.maxResults)
            .map(\.0)
    }

    public func markUsed(_ item: PaletteItem) {
        recents.removeAll { $0 == item.id }
        recents.insert(item.id, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast() }
    }

    /// Fuzzy subsequence score (higher is better), nil when `query` is not a subsequence of `candidate`.
    /// Bonuses: exact/prefix match, consecutive characters, matches at word starts.
    public static func score(_ query: String, _ candidate: String) -> Int? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard !q.isEmpty else { return 0 }
        guard q.count <= c.count else { return nil }
        if c == q { return 1_000 }
        var score = 0
        var qi = 0
        var previousMatch = -2
        for (ci, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            score += 10
            if ci == previousMatch + 1 { score += 15 }
            if ci == 0 { score += 25 } else if "-_./: ".contains(c[ci - 1]) { score += 12 }
            previousMatch = ci
            qi += 1
        }
        guard qi == q.count else { return nil }
        if candidate.lowercased().hasPrefix(query.lowercased()) { score += 100 }
        return score - (c.count - q.count)
    }
}
