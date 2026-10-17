import Foundation
import Observation

/// Sidebar sections in Docker Desktop order.
public enum SidebarSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case containers, images, volumes, networks, builds, machines, kubernetes, registries

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .containers: return "Containers"
        case .images: return "Images"
        case .volumes: return "Volumes"
        case .networks: return "Networks"
        case .builds: return "Builds"
        case .machines: return "Machines"
        case .kubernetes: return "Kubernetes"
        case .registries: return "Registries"
        }
    }

    public var symbol: String {
        switch self {
        case .containers: return "shippingbox"
        case .images: return "square.stack.3d.up"
        case .volumes: return "externaldrive"
        case .networks: return "network"
        case .builds: return "hammer"
        case .machines: return "desktopcomputer"
        case .kubernetes: return "helm"
        case .registries: return "server.rack"
        }
    }
}

/// Window-level navigation + chrome toggles. Deep links: `open(.containers, select: "web")`.
@MainActor
@Observable
public final class NavigationModel {
    public var section: SidebarSection? = .containers
    /// Item a feature view should select when it next appears (consumed once).
    public private(set) var pendingSelection: [SidebarSection: String] = [:]
    public var isPaletteOpen = false
    public var isTerminalOpen = false
    public var isCleanupOpen = false

    public init() {}

    /// Switches to `section` and asks its list view to select `id`.
    public func open(_ section: SidebarSection, select id: String? = nil) {
        self.section = section
        if let id { pendingSelection[section] = id }
    }

    /// Feature views call this in `.onAppear`/`.onChange(of: pendingSelection)` to pick up a deep link.
    public func consumeSelection(for section: SidebarSection) -> String? {
        pendingSelection.removeValue(forKey: section)
    }

    public func peekSelection(for section: SidebarSection) -> String? { pendingSelection[section] }
}
