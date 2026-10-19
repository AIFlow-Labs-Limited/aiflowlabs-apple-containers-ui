import AppKit
import AppCore

/// Shared wording + an `NSAlert` fallback for confirming `container system stop` from places that cannot host a
/// SwiftUI alert (menu bar extra, Debug menu). The main window uses `confirmDestructive` with the same text.
@MainActor
enum EngineStopConfirmation {
    static let title = "Stop the container system?"
    static let actionTitle = "Stop Container System"

    static func message(for model: AppModel) -> String {
        let running = model.containers.running.map(\.id)
        let base: String
        switch running.count {
        case 0: base = "No containers are running."
        case 1: base = "Stops 1 running container (\(running[0]))."
        default:
            let names = running.prefix(8).joined(separator: ", ") + (running.count > 8 ? " and \(running.count - 8) more" : "")
            base = "Stops \(running.count) running containers (\(names))."
        }
        return base + " The builder, machines and Kubernetes nodes stop too."
    }

    /// Modal confirmation; `true` when the user chose to stop.
    static func confirmModally(model: AppModel, title: String = title, actionTitle: String = actionTitle) -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message(for: model)
        let stop = alert.addButton(withTitle: actionTitle)
        stop.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        stop.keyEquivalent = ""   // Return does not stop the engine by accident
        return alert.runModal() == .alertFirstButtonReturn
    }
}
