#if DEBUG
import Foundation
import ContainerKit
import AppCore

/// DEBUG-only screenshot hooks for the containers section, read from the same variable as
/// `DebugLaunchActions` (which ignores these tokens):
/// `CONTAINER_DESKTOP_DEBUG_OPEN=section=containers,select=db,tab=stats` or `…,open=run[:<image>]`, or `runspec=<image>|<name>|<command>`.
@MainActor
enum ContainersDebugHooks {
    static func apply(to ui: ContainersUIState) async {
        guard let raw = ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_DEBUG_OPEN"], !raw.isEmpty else { return }
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        // Give the first list load a moment so selection lands on a real row.
        try? await Task.sleep(for: .milliseconds(900))
        var selected: String?
        for token in tokens {
            if token.hasPrefix("select=") {
                selected = String(token.dropFirst(7))
                ui.selection = [selected!]
                ui.showDetail = true
            } else if token.hasPrefix("tab="), let id = selected ?? ui.selection.first,
                      let tab = ContainerDetailTab(rawValue: String(token.dropFirst(4))) {
                ui.setTab(tab, for: id)
            } else if token == "open=run" {
                ui.runRequest = RunSheetRequest(spec: nil)
            } else if token.hasPrefix("runspec=") {
                // runspec=<image>|<name>|<command…>  (prefills the sheet; the user/automation presses Run)
                let parts = token.dropFirst(8).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                var spec = RunSpec(image: parts[0])
                if parts.count > 1, !parts[1].isEmpty { spec.name = parts[1] }
                if parts.count > 2 { spec.command = ShellWords.split(parts[2]) }
                ui.runRequest = RunSheetRequest(spec: spec)
            } else if token.hasPrefix("open=run:") {
                var spec = RunSpec(image: String(token.dropFirst(9)))
                spec.name = "web"
                spec.ports = [.init(hostPort: 8080, containerPort: 80)]
                spec.environment = ["APP_ENV=dev"]
                ui.runRequest = RunSheetRequest(spec: spec)
            }
        }
    }
}
#endif
