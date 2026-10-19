import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ContainerKit
import AppCore
import DesignSystem

/// Lifecycle + clipboard + export actions shared by the toolbar, row menus, context menus and detail header.
/// Destructive ones only *request* confirmation through `ui`; `ContainersListView` shows the alert.
@MainActor
struct ContainerActions {
    let model: AppModel
    let ui: ContainersUIState

    private var store: ContainersStore { model.containers }

    func containers(_ ids: [String]) -> [Container] { store.containerIDs(for: ids).compactMap(store.container(id:)) }

    // MARK: Lifecycle

    func start(_ ids: [String]) {
        let ids = store.containerIDs(for: ids)
        Task { report(await store.start(ids), verb: "Started", quietOnSuccess: true) }
    }
    func stop(_ ids: [String]) {
        let ids = store.containerIDs(for: ids)
        Task { report(await store.stop(ids), verb: "Stopped", quietOnSuccess: true) }
    }
    func restart(_ ids: [String]) {
        let ids = store.containerIDs(for: ids)
        Task { report(await store.restart(ids), verb: "Restarted", quietOnSuccess: true) }
    }
    func requestKill(_ ids: [String]) { ui.pendingKill = store.containerIDs(for: ids) }
    func requestDelete(_ ids: [String]) { ui.pendingDelete = store.containerIDs(for: ids) }

    func toggle(_ c: Container) { c.isRunning ? stop([c.id]) : start([c.id]) }

    func confirmDelete() {
        let ids = ui.pendingDelete
        ui.pendingDelete = []
        Task {
            // `force` only reaches running containers (they are killed, then removed).
            let result = await store.delete(ids, force: true)
            ui.selection.subtract(result.succeeded)
            report(result, verb: "Deleted", quietOnSuccess: false)
        }
    }

    func confirmKill() {
        let ids = ui.pendingKill
        ui.pendingKill = []
        Task { report(await store.kill(ids), verb: "Killed", quietOnSuccess: true) }
    }

    /// Bulk outcome as a toast: "Deleted 8 of 10 containers; failed: a (message), …".
    private func report(_ result: ContainersBulkResult, verb: String, quietOnSuccess: Bool) {
        guard result.attempted > 0 else { return }
        if result.isSuccess {
            if !quietOnSuccess || result.attempted > 1 { model.toasts.success(result.summary(verb: verb)) }
        } else {
            model.toasts.error(result.succeeded.isEmpty ? "Action failed" : "Partly completed",
                               message: result.summary(verb: verb))
        }
    }

    // MARK: Navigation

    func openTerminal(_ id: String) { ui.open(id, tab: .terminal) }
    func viewLogs(_ id: String) { ui.open(id, tab: .logs) }
    func run(_ spec: RunSpec? = nil) { ui.runRequest = RunSheetRequest(spec: spec) }

    // MARK: Clipboard / browser

    func copyIP(_ c: Container) { if let ip = c.primaryIPv4 { copyToPasteboard(ip) } }
    func copyID(_ c: Container) { copyToPasteboard(c.id) }

    /// Copies the `container run …` equivalent. Looks up the image config so entrypoint/env defaults are omitted.
    func copyRunCommand(_ c: Container) {
        let backend = model.backend
        Task {
            let config = await Self.imageConfig(for: c, backend: backend)
            let spec = RunSpec(recreating: c, imageConfig: config)
            guard let text = SecretCopyPrompt.runCommand(for: spec) else { return }
            copyToPasteboard(text)
            model.toasts.info("Copied container run command", message: c.id)
        }
    }

    /// Opens the Run sheet prefilled with this container's settings (name cleared so it does not clash).
    func runSimilar(_ c: Container) {
        let backend = model.backend
        Task {
            var spec = RunSpec(recreating: c, imageConfig: await Self.imageConfig(for: c, backend: backend))
            spec.name = nil
            run(spec)
        }
    }

    static func imageConfig(for c: Container, backend: any ContainerBackend) async -> ContainerKit.Image.OCIConfig.RuntimeConfig? {
        guard let image = try? await backend.inspectImage(c.imageReference) else { return nil }
        let arch = c.configuration.platform.architecture
        return (image.variants.first { $0.platform.architecture == arch } ?? image.variants.first)?.config?.config
    }

    func openInBrowser(_ port: Container.PublishedPort) {
        if let url = port.hostURL { NSWorkspace.shared.open(url) }
    }

    func openFirstPort(_ c: Container) { if let p = c.configuration.publishedPorts.first { openInBrowser(p) } }

    // MARK: Export

    /// Asks for a destination, then runs `exportContainer` as an Activity task.
    func export(_ c: Container) {
        let panel = NSSavePanel()
        panel.title = "Export “\(c.id)”"
        panel.nameFieldStringValue = "\(c.id).tar"
        panel.allowedContentTypes = [UTType(filenameExtension: "tar") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let backend = model.backend
        let id = c.id
        let path = url.path
        model.taskCenter.run(title: "Export \(id)", kind: .other, stream: .single {
            try await backend.exportContainer(id, to: path)
            return "Exported \(id) to \(path)"
        })
    }
}

extension AsyncThrowingStream where Element == OutputLine, Failure == any Error {
    /// Wraps a one-shot async action as a `LineStream` so it can run in `TaskCenter` (Activity window).
    static func single(_ work: @escaping @Sendable () async throws -> String) -> LineStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let message = try await work()
                    continuation.yield(OutputLine(message))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The ⋯ / context menu for one or more containers (project rows expand to their members).
struct ContainerMenuItems: View {
    let ids: [String]
    let actions: ContainerActions

    var body: some View {
        let containers = actions.containers(ids)
        let single = containers.count == 1 ? containers.first : nil
        if containers.contains(where: { !$0.isRunning }) {
            Button("Start", systemImage: "play.fill") { actions.start(ids) }
        }
        if containers.contains(where: \.isRunning) {
            Button("Stop", systemImage: "stop.fill") { actions.stop(ids) }
        }
        Button("Restart", systemImage: "arrow.clockwise") { actions.restart(ids) }
            .disabled(containers.isEmpty)
        if containers.contains(where: \.isRunning) {
            Button("Kill…", systemImage: "bolt.fill") { actions.requestKill(ids) }
        }
        if let c = single {
            Divider()
            Button("Open Terminal", systemImage: "terminal") { actions.openTerminal(c.id) }
                .disabled(!c.isRunning)
            Button("View Logs", systemImage: "text.alignleft") { actions.viewLogs(c.id) }
            if let port = c.configuration.publishedPorts.first, let url = port.hostURL {
                Button("Open \(url.absoluteString)", systemImage: "safari") { actions.openInBrowser(port) }
            }
            Divider()
            if c.primaryIPv4 != nil { Button("Copy IP Address") { actions.copyIP(c) } }
            Button("Copy ID") { actions.copyID(c) }
            Button("Copy “container run” Command") { actions.copyRunCommand(c) }
            Button("Run Similar…") { actions.runSimilar(c) }
            Divider()
            Button("Export…", systemImage: "square.and.arrow.up") { actions.export(c) }
        }
        Divider()
        Button(containers.count > 1 ? "Delete \(containers.count) Containers…" : "Delete…", systemImage: "trash", role: .destructive) {
            actions.requestDelete(ids)
        }
        .disabled(containers.isEmpty)
    }
}
