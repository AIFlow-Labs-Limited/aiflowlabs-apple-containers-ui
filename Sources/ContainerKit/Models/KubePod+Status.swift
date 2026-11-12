import Foundation

// What `kubectl get pods` shows in its READY, STATUS and RESTARTS columns, derived the way kubectl's own
// printer derives it, so the table agrees with the terminal.

/// How a pod is doing, for the status colour.
public enum KubePodHealth: String, Hashable, Sendable {
    /// Running with every container ready.
    case healthy
    /// Starting, stopping or not ready yet.
    case progressing
    /// Crash loop, image pull failure, error exit, eviction.
    case failing
    /// Ran to completion.
    case completed
}

extension KubePod {
    /// Statuses of the regular (non-init) containers.
    public var containerStatuses: [ContainerStatus] { status?.containerStatuses ?? [] }

    /// Number of regular containers the pod declares.
    public var containerCount: Int { max(spec?.containers?.count ?? 0, containerStatuses.count) }

    /// Regular containers that are ready.
    public var readyCount: Int { containerStatuses.count { $0.ready == true } }

    /// `1/2`, as in the READY column.
    public var readyText: String { "\(readyCount)/\(containerCount)" }

    /// Restarts of all regular containers together.
    public var restartCount: Int { containerStatuses.reduce(0) { $0 + ($1.restartCount ?? 0) } }

    /// When a container last restarted (the end of its previous instance); `nil` without restarts.
    public var lastRestart: Date? {
        containerStatuses.compactMap { $0.lastState?.terminated?.finishedAt }.max()
    }

    /// The node the pod is scheduled on.
    public var nodeName: String? { spec?.nodeName }

    /// The Deployment's ReplicaSet (or other controller) that owns the pod; `nil` for a bare pod.
    public var ownerName: String? { metadata.ownerReferences?.first?.name }

    /// The STATUS column: `Running`, `CrashLoopBackOff`, `ImagePullBackOff`, `Init:0/1`, `Terminating`, …
    public var statusText: String {
        var reason = status?.reason ?? status?.phase?.rawValue ?? KubePodPhase.unknown.rawValue
        var initializing = false
        let initStatuses = status?.initContainerStatuses ?? []
        for (index, container) in initStatuses.enumerated() {
            if let terminated = container.state?.terminated {
                if terminated.exitCode == 0 { continue }
                reason = "Init:" + Self.terminationReason(terminated)
            } else if let waiting = container.state?.waiting?.reason, !waiting.isEmpty, waiting != "PodInitializing" {
                reason = "Init:" + waiting
            } else if container.state?.running != nil, container.started == true, container.ready == true {
                continue  // a sidecar (restartable init container) that is up
            } else {
                reason = "Init:\(index)/\(spec?.initContainers?.count ?? initStatuses.count)"
            }
            initializing = true
            break
        }
        if !initializing {
            var hasRunning = false
            for container in containerStatuses.reversed() {
                if let waiting = container.state?.waiting?.reason, !waiting.isEmpty {
                    reason = waiting
                } else if let terminated = container.state?.terminated {
                    reason = Self.terminationReason(terminated)
                } else if container.ready == true, container.state?.running != nil {
                    hasRunning = true
                }
            }
            // One container finished while another still runs: the pod itself is running.
            if reason == "Completed", hasRunning { reason = isReadyCondition ? "Running" : "NotReady" }
        }
        if metadata.deletionTimestamp != nil { return reason == "NodeLost" ? "Unknown" : "Terminating" }
        return reason
    }

    /// The longer explanation behind `statusText`, when the API gives one (a failed pull's error, an eviction).
    public var statusMessage: String? {
        for container in (status?.initContainerStatuses ?? []) + containerStatuses {
            if let message = container.state?.waiting?.message, !message.isEmpty { return message }
            if let message = container.state?.terminated?.message, !message.isEmpty { return message }
        }
        return status?.message
    }

    /// Health for the status colour, from `statusText`.
    public var health: KubePodHealth {
        let text = statusText
        if text == "Completed" || text == "Succeeded" { return .completed }
        if text == "Running" { return readyCount == containerCount && containerCount > 0 ? .healthy : .progressing }
        let failing = [
            "BackOff", "Err", "Failed", "Evicted", "OOMKilled", "Invalid", "ExitCode", "Signal", "Unknown",
            "NodeLost", "CreateContainerConfig", "DeadlineExceeded",
        ]
        return failing.contains { text.contains($0) } ? .failing : .progressing
    }

    private var isReadyCondition: Bool {
        status?.conditions?.contains { $0.type == "Ready" && $0.status == "True" } ?? false
    }

    private static func terminationReason(_ terminated: StateDetail.Terminated) -> String {
        if let reason = terminated.reason, !reason.isEmpty { return reason }
        if let signal = terminated.signal, signal != 0 { return "Signal:\(signal)" }
        return "ExitCode:\(terminated.exitCode ?? 0)"
    }
}

extension KubePod.ContainerStatus {
    /// `Running`, `Waiting: CrashLoopBackOff`, `Terminated: Error (exit 1)`.
    public var stateText: String {
        if state?.running != nil { return "Running" }
        if let waiting = state?.waiting { return "Waiting: " + (waiting.reason ?? "unknown") }
        if let terminated = state?.terminated { return "Terminated: " + Self.describe(terminated) }
        return "Unknown"
    }

    /// The previous instance (`Error (exit 1)`), when the container was restarted.
    public var lastStateText: String? { lastState?.terminated.map(Self.describe) }

    /// Whether `kubectl logs --previous` has something to show.
    public var hasPreviousInstance: Bool { lastState?.terminated != nil }

    private static func describe(_ terminated: KubePod.StateDetail.Terminated) -> String {
        let reason = terminated.reason ?? "Exited"
        if let signal = terminated.signal, signal != 0 { return "\(reason) (signal \(signal))" }
        return terminated.exitCode.map { "\(reason) (exit \($0))" } ?? reason
    }
}
