#if DEBUG
import SwiftUI
import Observation
import AppCore
import ContainerKit

/// DEBUG-only requests from `DebugLaunchActions` (e.g. `machine-create`) that the platform views pick up to open
/// their sheets for screenshots. Observable so a request that arrives after the view appeared still fires.
@MainActor
@Observable
final class DebugPlatformHooks {
    static let shared = DebugPlatformHooks()
    private(set) var pending: Set<String> = []

    static func request(_ token: String) { shared.pending.insert(token) }

    /// Returns `true` once per requested token.
    static func consume(_ token: String) -> Bool { shared.pending.remove(token) != nil }
}

/// `e2e-machine`: real-engine check through the same store calls the UI makes (create sheet → stop → delete).
@MainActor
enum PlatformEndToEnd {
    static func machine(model: AppModel, name: String = "cd-ui-test") async {
        func log(_ s: String) { FileHandle.standardError.write(Data("[E2E] \(s)\n".utf8)) }
        var form = MachineForm()
        form.name = name
        form.cpus = 2
        form.memoryGB = 2
        log("create: \(form.previewCommand())")
        let task = model.machines.create(form.spec)
        await task.wait()
        log("create finished: \(task.state.label) \(task.lines.suffix(3).map(\.text))")
        if case .failed(let e) = task.state { log("error: \(e.localizedDescription)") }
        await model.machines.refresh()
        let m = model.machines.items.first { $0.name == name }
        log("listed: \(m.map { "\($0.name) \($0.status.rawValue) cpus=\($0.cpus) mem=\($0.memory >> 30)g" } ?? "MISSING")")
        model.navigation.open(.machines, select: name)
        try? await Task.sleep(for: .seconds(8))  // time for a screenshot of the running machine
        await model.machines.stop([name])
        log("after stop: \(model.machines.items.first { $0.name == name }?.status.rawValue ?? "MISSING") err=\(model.machines.lastError?.localizedDescription ?? "none")")
        await model.machines.delete([name])
        log("after delete present=\(model.machines.items.contains { $0.name == name }) err=\(model.machines.lastError?.localizedDescription ?? "none")")
        log("done")
    }
}

extension PlatformEndToEnd {
    /// `e2e-cluster`: one real `k8s create` (cancelled after 10 min), list, then delete.
    static func cluster(model: AppModel, name: String = "cd-ui-test") async {
        func log(_ s: String) { FileHandle.standardError.write(Data("[E2E] \(s)\n".utf8)) }
        await model.clusters.refresh()
        log("available=\(model.clusters.available)")
        guard model.clusters.available else { log("done"); return }
        var form = ClusterForm()
        form.name = name
        log("create: \(form.previewCommand())")
        let started = Date.now
        let task = model.clusters.create(form.spec)
        let watchdog = Task { @MainActor in
            try? await Task.sleep(for: .seconds(600))
            if task.state == .running { log("timeout after 10 min, cancelling"); task.cancel() }
        }
        await task.wait()
        watchdog.cancel()
        log("create finished: \(task.state.label) in \(Int(Date.now.timeIntervalSince(started)))s; last: \(task.lines.suffix(4).map(\.text))")
        if case .failed(let e) = task.state { log("error: \(e.localizedDescription)") }
        await model.clusters.refresh()
        let c = model.clusters.items.first { $0.name == name }
        log("listed: \(c.map { "\($0.name) nodes=\($0.nodes.map { "\($0.name)/\($0.role)/\($0.state.displayName)/\($0.address ?? "-")" })" } ?? "MISSING")")
        model.navigation.open(.kubernetes, select: name)
        try? await Task.sleep(for: .seconds(8))
        await model.clusters.delete([name])
        log("after delete present=\(model.clusters.items.contains { $0.name == name }) err=\(model.clusters.lastError?.localizedDescription ?? "none")")
        log("done")
    }
}

extension View {
    /// Runs `action` when the DEBUG hook `token` is requested (now or later).
    func debugHook(_ token: String, perform action: @escaping () -> Void) -> some View {
        onChange(of: DebugPlatformHooks.shared.pending, initial: true) {
            if DebugPlatformHooks.consume(token) { action() }
        }
    }
}
#endif
