import ContainerKit
import Foundation

/// Plain-text bug-report blob for Settings → About → "Copy diagnostics". Contains no secrets.
@MainActor
public enum Diagnostics {
    public static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    public static func report(for model: AppModel, now: Date = .now) -> String {
        var lines: [String] = []
        lines.append("Container Desktop diagnostics — \(now.formatted(.iso8601))")
        lines.append("")
        lines.append("App version: \(appVersion)")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("Backend: \(model.backend.backendDescription)")
        lines.append("Engine: \(describe(model.engine))")
        if let s = model.engine.status ?? model.system.status {
            lines.append("CLI client: \(s.client?.version ?? "?")  server: \(s.server?.version ?? "?")")
            if let host = s.host {
                lines.append("Host: \(host.operatingSystem) \(host.architecture), \(host.cpus) CPUs")
            }
            if let r = s.resources {
                lines.append(
                    "Resources: \(r.containersRunning)/\(r.containersTotal) containers running, \(r.images) images")
            }
        }
        lines.append(
            "Counts: containers=\(model.containers.items.count) images=\(model.images.items.count) volumes=\(model.volumes.items.count) "
                + "networks=\(model.networks.items.count) machines=\(model.machines.items.count) clusters=\(model.clusters.items.count)"
        )
        lines.append("Tasks: \(model.taskCenter.activeCount) active, \(model.taskCenter.tasks.count) retained")
        lines.append("")
        lines.append("Settings:")
        for (k, v) in model.settings.summary { lines.append("  \(k): \(v)") }
        lines.append("")
        lines.append("Recent errors:")
        if model.recentErrors.isEmpty { lines.append("  (none)") }
        for e in model.recentErrors {
            lines.append(
                "  [\(e.date.formatted(date: .omitted, time: .standard))] \(e.error.errorDescription ?? "\(e.error)")")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ state: EngineState) -> String {
        switch state {
        case .notInstalled(let paths): return "not installed (searched \(paths.joined(separator: ", ")))"
        case .running(let s): return "running (\(s.server?.version ?? s.client?.version ?? "unknown version"))"
        case .error(let e): return "error — \(e.errorDescription ?? "\(e)")"
        default: return state.label
        }
    }
}
