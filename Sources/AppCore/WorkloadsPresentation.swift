import ContainerKit
import Foundation

// Display strings for workloads, kept out of the views so they can be unit-tested.

/// Ages the way `kubectl get` prints them: `45s`, `4m19s`, `3h12m`, `2d4h`, `41d`.
public enum KubeAge {
    /// The age of something created at `date`, or `nil` for an unknown date.
    public static func format(since date: Date?, now: Date = .now) -> String? {
        date.map { format(seconds: Int(now.timeIntervalSince($0))) }
    }

    public static func format(seconds raw: Int) -> String {
        let seconds = max(0, raw)
        let minutes = seconds / 60
        let hours = minutes / 60
        let days = hours / 24
        switch seconds {
        case ..<120: return "\(seconds)s"
        case ..<600: return seconds % 60 == 0 ? "\(minutes)m" : "\(minutes)m\(seconds % 60)s"
        case ..<10_800: return "\(minutes)m"
        case ..<28_800: return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h\(minutes % 60)m"
        case ..<172_800: return "\(hours)h"
        case ..<691_200: return hours % 24 == 0 ? "\(days)d" : "\(days)d\(hours % 24)h"
        default: return "\(days)d"
        }
    }
}

extension KubePod {
    /// `3 (2m ago)`, as in the RESTARTS column; `0` without restarts.
    public func restartsText(now: Date = .now) -> String {
        guard restartCount > 0, let ago = KubeAge.format(since: lastRestart, now: now) else { return "\(restartCount)" }
        return "\(restartCount) (\(ago) ago)"
    }
}

extension KubeNode {
    /// `control-plane`, or `worker` for a node without a role label (kubectl prints `<none>`).
    public var rolesText: String { roles.isEmpty ? "worker" : roles.joined(separator: ",") }
}

extension KubeEvent {
    /// `Pulled ×4` when the event repeated.
    public var reasonText: String {
        let reason = reason ?? "Event"
        return (count ?? 1) > 1 ? "\(reason) ×\(count ?? 1)" : reason
    }
}

/// One tab of the workloads view.
public enum WorkloadKind: String, CaseIterable, Identifiable, Sendable {
    case pods, deployments, services, nodes

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

extension ClusterWorkloadsStore {
    /// How many rows a tab shows with the current filters.
    public func count(of kind: WorkloadKind) -> Int {
        switch kind {
        case .pods: return pods.count
        case .deployments: return deployments.count
        case .services: return services.count
        case .nodes: return nodes.count
        }
    }

    /// `3 of 5 pods are not ready`-style headline for the tab bar; `nil` when every pod is fine.
    public var troubleSummary: String? {
        let failing = pods.count { $0.health == .failing }
        guard failing > 0 else { return nil }
        return failing == 1 ? "1 pod is failing" : "\(failing) pods are failing"
    }
}
