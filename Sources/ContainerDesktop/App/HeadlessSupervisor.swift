import AppCore
import ContainerKit
import Foundation
import os

/// The executable's windowless modes. No `NSApplication` is created, so there is no Dock icon and no menu bar.
///
/// * `--supervise`: the background helper. Enforces restart policies with the real CLI until SIGTERM. Started by
///   the LaunchAgent that Settings › General › "Keep enforcing when Container Desktop is closed" registers.
/// * `--background-supervision status|register|unregister`: the same switch from a terminal (for scripts, and for
///   removing the helper without opening the app).
enum HeadlessSupervisor {
    static let controlArgument = "--background-supervision"

    static func handles(_ arguments: [String]) -> Bool {
        arguments.contains(LaunchAgentSupervisionService.superviseArgument) || arguments.contains(controlArgument)
    }

    static func main(_ arguments: [String]) -> Never {
        if let index = arguments.firstIndex(of: controlArgument) {
            exit(control(arguments.dropFirst(index + 1).first ?? "status"))
        }
        supervise()
    }

    // MARK: --supervise

    private static func supervise() -> Never {
        let logger = Logger(subsystem: "io.aiflowlabs.containerdesktop", category: "supervisor")
        // Messages carry container names and CLI error text only, so they are logged in the clear.
        let log: @MainActor (String) -> Void = { message in logger.notice("\(message, privacy: .public)") }
        let signals = TerminationSignals.stream()
        MainActor.assumeIsolated {
            let sharing = SupervisionSharing.helper()
            let helper = BackgroundSupervisor(
                backend: locateBackend() ?? UnavailableBackend(searchedPaths: CLIBackend.searchPaths()),
                state: sharing.state, claim: sharing.claim, isEnabled: { restartPoliciesEnabled },
                locateBackend: locateBackend, log: log)
            let work = Task { await helper.run() }
            Task {
                for await _ in signals { break }
                work.cancel()
                await work.value
                exit(EXIT_SUCCESS)
            }
        }
        // A timer keeps the run loop (which also drives the main actor) alive without any work to do.
        let keepAlive = Timer(timeInterval: 86_400, repeats: true) { _ in }
        RunLoop.main.add(keepAlive, forMode: .common)
        RunLoop.main.run()
        exit(EXIT_FAILURE)
    }

    @MainActor
    private static func locateBackend() -> (any ContainerBackend)? { try? CLIBackend() }

    /// The app's "Enforce restart policies" switch (on unless the user turned it off).
    @MainActor
    private static var restartPoliciesEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsStore.Key.restartPoliciesEnabled) as? Bool ?? true
    }

    // MARK: --background-supervision

    private static func control(_ verb: String) -> Int32 {
        let service = LaunchAgentSupervisionService()
        do {
            switch verb {
            case "register": try service.enable()
            case "unregister": try service.disable()
            case "status": break
            default:
                print("usage: ContainerDesktop \(controlArgument) status|register|unregister")
                return 64
            }
        } catch {
            print("failed: \(error.localizedDescription)")
            return EXIT_FAILURE
        }
        print(describe(service.status()))
        return EXIT_SUCCESS
    }

    private static func describe(_ status: BackgroundSupervisionStatus) -> String {
        switch status {
        case .disabled: return "disabled"
        case .enabled: return "enabled"
        case .requiresApproval:
            return "installed, but macOS is not running it (check System Settings › General › Login Items)"
        case .unavailable(let reason): return "unavailable: \(reason)"
        }
    }
}
