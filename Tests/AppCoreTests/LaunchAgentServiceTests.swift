import Foundation
import Synchronization
import Testing

@testable import AppCore

/// A `launchctl` that keeps the one job in memory and records what it was asked.
final class FakeLaunchd: Sendable {
    private struct State {
        var loaded = false
        var bootstrapFails = false
        var calls: [[String]] = []
    }
    private let state = Mutex(State())

    var isLoaded: Bool { state.withLock { $0.loaded } }
    var calls: [[String]] { state.withLock { $0.calls } }
    func verbs() -> [String] { calls.compactMap(\.first).filter { $0 != "print" } }
    func setLoaded(_ loaded: Bool) { state.withLock { $0.loaded = loaded } }
    func setBootstrapFails(_ fails: Bool) { state.withLock { $0.bootstrapFails = fails } }
    func forgetCalls() { state.withLock { $0.calls = [] } }

    func run(_ arguments: [String]) -> (status: Int32, output: String) {
        state.withLock { state in
            state.calls.append(arguments)
            switch arguments.first {
            case "print": return state.loaded ? (0, "state = running") : (113, "Could not find service")
            case "bootout":
                state.loaded = false
                return (0, "")
            case "bootstrap":
                if state.bootstrapFails { return (5, "Bootstrap failed: 5: Input/output error\n") }
                state.loaded = true
                return (0, "")
            default: return (0, "")
            }
        }
    }
}

@Suite("Background helper: LaunchAgent")
struct LaunchAgentServiceTests {
    let launchd = FakeLaunchd()
    let folder = FileManager.default.temporaryDirectory.appending(path: "cd-agent-\(UUID().uuidString)")
    var plist: URL { folder.appending(path: "LaunchAgents/\(LaunchAgentSupervisionService.label).plist") }

    private func service(
        executable: String? = "/Applications/Container Desktop.app/Contents/MacOS/ContainerDesktop",
        version: String = "0.2.0 (171)"
    ) -> LaunchAgentSupervisionService {
        let launchd = launchd
        return LaunchAgentSupervisionService(
            executable: executable.map { URL(fileURLWithPath: $0) }, plistURL: plist, version: version,
            bundleIdentifier: "io.aiflowlabs.containerdesktop", domain: "gui/501", launchctl: { launchd.run($0) })
    }

    private func installed() throws -> [String: Any] {
        let data = try Data(contentsOf: plist)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func enablingWritesTheAgentAndLoadsIt() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = service()
        #expect(service.status() == .disabled)
        try service.enable()
        #expect(service.status() == .enabled)
        let agent = try installed()
        #expect(agent["Label"] as? String == "io.aiflowlabs.containerdesktop.supervisor")
        #expect(
            agent["ProgramArguments"] as? [String]
                == ["/Applications/Container Desktop.app/Contents/MacOS/ContainerDesktop", "--supervise"])
        #expect(agent["RunAtLoad"] as? Bool == true)
        #expect(agent["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
        #expect(launchd.calls.contains(["bootstrap", "gui/501", plist.path]))
    }

    @Test func disablingStopsTheAgentAndLeavesNothingOnDisk() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = service()
        try service.enable()
        try service.disable()
        #expect(!launchd.isLoaded)
        #expect(!FileManager.default.fileExists(atPath: plist.path))
        #expect(service.status() == .disabled)
        #expect(launchd.calls.contains(["bootout", "gui/501/io.aiflowlabs.containerdesktop.supervisor"]))
        try service.disable()  // nothing installed: not an error
    }

    @Test func aCopyThatCannotHostTheHelperSaysSoAndTouchesNothing() {
        let service = service(executable: nil)
        guard case .unavailable = service.status() else {
            Issue.record("expected .unavailable, got \(service.status())")
            return
        }
        #expect(throws: LaunchAgentError.self) { try service.enable() }
        #expect(launchd.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }

    @Test func anInstalledAgentThatIsNotLoadedIsReportedAsSuch() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let service = service()
        try service.enable()
        launchd.setLoaded(false)  // switched off under Login Items, or booted out by hand
        #expect(service.status() == .requiresApproval)
        // Loading it again fails: the reason launchctl gave reaches the user, and the state stays honest.
        launchd.setBootstrapFails(true)
        #expect(
            throws: LaunchAgentError("launchctl could not load the helper: Bootstrap failed: 5: Input/output error")
        ) {
            try service.enable()
        }
        #expect(service.status() == .requiresApproval)
    }

    @Test func anUpdatedOrMovedAppReplacesItsHelper() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try service().enable()
        launchd.forgetCalls()
        // Same app: nothing happens, the running helper is left alone.
        try service().repairIfNeeded()
        #expect(launchd.verbs().isEmpty)
        // A newer build: the old helper is stopped and the new one loaded.
        try service(version: "0.3.0 (200)").repairIfNeeded()
        #expect(launchd.verbs() == ["bootout", "enable", "bootstrap"])
        #expect(launchd.isLoaded)
        // The app moved: the agent follows it.
        try service(
            executable: "/Users/me/Apps/Container Desktop.app/Contents/MacOS/ContainerDesktop", version: "0.3.0 (200)"
        )
        .repairIfNeeded()
        #expect(
            (try installed()["ProgramArguments"] as? [String])?.first
                == "/Users/me/Apps/Container Desktop.app/Contents/MacOS/ContainerDesktop")
        // Not installed: nothing to repair, and nothing gets installed.
        try service().disable()
        launchd.forgetCalls()
        try service(version: "0.4.0 (300)").repairIfNeeded()
        #expect(launchd.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: plist.path))
    }
}
