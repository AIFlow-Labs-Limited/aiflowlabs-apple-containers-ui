import ContainerKit
import ContainerKitMock
import Foundation
import Synchronization
import Testing

@testable import AppCore

/// What a test sets and reads around the helper: the Settings switch and the log lines.
@MainActor
final class HelperControls {
    var enabled = true
    var lines: [String] = []
}

/// The helper's loop on a mock engine: `step()` is one pass, as `run()` makes every few seconds.
@MainActor
struct HelperHarness {
    let backend = MockBackend()
    let clock = FakeClock()
    let paths = SupervisionPaths(
        directory: FileManager.default.temporaryDirectory.appending(path: "cd-helper-\(UUID().uuidString)"))
    let controls = HelperControls()
    let helper: BackgroundSupervisor

    init(
        backend initial: (any ContainerBackend)? = nil, located: (any ContainerBackend)? = nil,
        initialDelay: TimeInterval = 0
    ) async {
        let clock = clock
        let controls = controls
        await backend.setLatency(.zero)
        await backend.setClock { clock.now }
        var timing = RestartSupervisor.Timing()
        timing.initialDelay = initialDelay
        helper = BackgroundSupervisor(
            backend: initial ?? backend, state: FileSupervisionState(url: paths.state),
            claim: EnforcementClaim(role: .helper, paths: paths), isEnabled: { controls.enabled },
            locateBackend: { located }, timing: timing, now: { clock.now },
            log: { controls.lines.append($0) })
    }

    func add(_ id: String, policy: String?, running: Bool = true) async {
        await backend.addContainer(id: id, labels: policy.map { [AppLabel.restart: $0] } ?? [:], running: running)
    }

    /// One pass, then a second on the clock.
    @discardableResult
    func step() async -> Duration {
        let delay = await helper.step()
        clock.advance(1)
        return delay
    }

    func starts(_ id: String) async -> Int { await backend.startCounts[id] ?? 0 }
    var log: [String] { controls.lines }
    func cleanUp() { try? FileManager.default.removeItem(at: paths.directory) }
}

@MainActor
@Suite("Background helper loop")
struct BackgroundSupervisorTests {
    @Test func itRestartsWhatStopsAndStartsAlwaysOnItsFirstPass() async {
        let h = await HelperHarness()
        defer { h.cleanUp() }
        await h.add("db", policy: "always")
        await h.add("down", policy: "always", running: false)
        await h.add("job", policy: "on-failure", running: false)
        await h.add("plain", policy: nil, running: false)
        #expect(await h.step() == .seconds(10))
        #expect(h.helper.phase == .supervising(policies: 3))
        // The helper starting is a launch: `always` comes up, `on-failure` and unlabelled containers do not.
        #expect(await h.backend.startCounts == ["down": 1])
        await h.backend.simulateExitIgnoringErrors("db")
        await h.step()
        #expect(await h.starts("db") == 1)
        #expect(h.log.contains("Restart db, attempt 1"))
        #expect(h.log.contains("Enforcing restart policies (3 containers with a policy)."))
    }

    @Test func aScheduledRestartBringsTheNextPassForward() async {
        let h = await HelperHarness(initialDelay: 1)
        defer { h.cleanUp() }
        await h.add("db", policy: "always")
        await h.step()
        await h.backend.simulateExitIgnoringErrors("db")
        // Seen stopped: the restart is due in 1 s, so the helper does not sleep its full 10 s.
        #expect(await h.step() == .seconds(1))
        #expect(await h.starts("db") == 0)
        #expect(await h.step() == .seconds(10))
        #expect(await h.starts("db") == 1)
    }

    @Test func itSlowsDownWhenNoContainerHasAPolicy() async {
        let h = await HelperHarness()
        defer { h.cleanUp() }
        await h.add("plain", policy: nil)
        #expect(await h.step() == .seconds(30))
        #expect(h.helper.phase == .supervising(policies: 0))
        await h.add("db", policy: "unless-stopped")
        #expect(await h.step() == .seconds(10))
    }

    @Test func itWaitsForTheContainerSystemWithoutSpinning() async throws {
        let h = await HelperHarness()
        defer { h.cleanUp() }
        await h.add("db", policy: "always")
        await h.step()
        try await h.backend.systemStop()
        await h.backend.simulateExitIgnoringErrors("db")
        // Down: nothing is started, and the wait grows to the poller's ceiling instead of retrying at once.
        var delays: [Duration] = []
        for _ in 0..<4 { delays.append(await h.step()) }
        #expect(delays == [.seconds(20), .seconds(30), .seconds(30), .seconds(30)])
        #expect(h.helper.phase == .waitingForEngine)
        #expect(await h.backend.startCounts.isEmpty)
        #expect(h.log.filter { $0.contains("not running") }.count == 1)  // said once, not every pass
        // Up again: back to the normal rate, and `always` is started as after a launch.
        try await h.backend.systemStart()
        #expect(await h.step() == .seconds(10))
        #expect(await h.starts("db") == 1)
    }

    @Test func itPicksUpTheCLIOnceItIsInstalled() async {
        let real = MockBackend()
        await real.setLatency(.zero)
        await real.addContainer(id: "svc", labels: [AppLabel.restart: "always"], running: false)
        let h = await HelperHarness(backend: UnavailableBackend(searchedPaths: ["/nowhere"]), located: real)
        defer { h.cleanUp() }
        #expect(await h.step() == .seconds(20))
        #expect(h.helper.phase == .waitingForEngine)
        await h.step()
        #expect(await real.startCounts == ["svc": 1])
    }

    @Test func switchedOffItDoesNothingAndLetsGo() async {
        let h = await HelperHarness()
        defer { h.cleanUp() }
        await h.add("down", policy: "always", running: false)
        h.controls.enabled = false
        #expect(await h.step() == .seconds(30))
        #expect(h.helper.phase == .switchedOff)
        #expect(await h.backend.startCounts.isEmpty)
        #expect(!FileLock.isLockedElsewhere(h.paths.helperLock))
        // Switching enforcement on is a launch, as in the app.
        h.controls.enabled = true
        await h.step()
        #expect(await h.starts("down") == 1)
    }

    @Test func itStandsByWhileTheAppStillEnforces() async {
        let h = await HelperHarness()
        defer { h.cleanUp() }
        await h.add("down", policy: "always", running: false)
        let app = EnforcementClaim(role: .app, paths: h.paths)
        #expect(app.hold())
        #expect(await h.step() == .seconds(10))
        #expect(h.helper.phase == .standingBy)
        #expect(await h.backend.startCounts.isEmpty)
        #expect(!app.hold())  // the app notices the helper and lets go
        await h.step()
        #expect(h.helper.phase == .supervising(policies: 1))
    }

    @Test func runEndsWhenCancelledAndReleasesItsClaim() async {
        let h = await HelperHarness()
        defer { h.cleanUp() }
        await h.add("db", policy: "always")
        let helper = h.helper
        let work = Task { await helper.run() }
        for _ in 0..<200 where helper.passes == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(helper.passes == 1)
        #expect(FileLock.isLockedElsewhere(h.paths.enforcerLock))
        work.cancel()  // what SIGTERM does
        await work.value
        #expect(helper.passes == 1)  // it was asleep, not polling
        #expect(!FileLock.isLockedElsewhere(h.paths.enforcerLock))
        #expect(!FileLock.isLockedElsewhere(h.paths.helperLock))
        #expect(h.log.first == "Background supervision started.")
        #expect(h.log.last == "Background supervision stopped.")
    }
}

/// A login-agent service that only remembers what it was asked.
final class FakeSupervisionService: BackgroundSupervisionService {
    struct Refused: LocalizedError {
        var errorDescription: String? { "Operation not permitted" }
    }
    private struct State {
        var status: BackgroundSupervisionStatus = .disabled
        var statusAfterEnable: BackgroundSupervisionStatus = .enabled
        var fails = false
    }
    private let state = Mutex(State())

    func status() -> BackgroundSupervisionStatus { state.withLock { $0.status } }
    func setStatus(_ status: BackgroundSupervisionStatus) { state.withLock { $0.status = status } }
    func setStatusAfterEnable(_ status: BackgroundSupervisionStatus) {
        state.withLock { $0.statusAfterEnable = status }
    }
    func setFails(_ fails: Bool) { state.withLock { $0.fails = fails } }

    func enable() throws {
        try state.withLock {
            if $0.fails { throw Refused() }
            $0.status = $0.statusAfterEnable
        }
    }
    func disable() throws {
        try state.withLock {
            if $0.fails { throw Refused() }
            $0.status = .disabled
        }
    }
    func repairIfNeeded() throws {}
}

@MainActor
@Suite("Settings: background helper switch")
struct BackgroundSupervisionSettingsTests {
    private func settings(_ service: FakeSupervisionService) -> SettingsStore {
        SettingsStore(defaults: TestSupport.defaults(), supervisionService: service)
    }

    @Test func theSwitchRegistersAndRemovesTheHelper() {
        let service = FakeSupervisionService()
        let store = settings(service)
        #expect(!store.keepEnforcingWhenClosed && store.backgroundSupervision == .disabled)
        store.keepEnforcingWhenClosed = true
        #expect(service.status() == .enabled)
        #expect(store.keepEnforcingWhenClosed && store.backgroundSupervision == .enabled)
        store.keepEnforcingWhenClosed = false
        #expect(service.status() == .disabled)
        #expect(!store.keepEnforcingWhenClosed && store.backgroundSupervisionError == nil)
    }

    @Test func theSwitchShowsWhatMacOSSaysNotWhatWasAsked() {
        let service = FakeSupervisionService()
        let store = settings(service)
        // Registered, but waiting for the user in Login Items.
        service.setStatusAfterEnable(.requiresApproval)
        store.keepEnforcingWhenClosed = true
        #expect(store.keepEnforcingWhenClosed && store.backgroundSupervision == .requiresApproval)
        // The user removed it in System Settings while the app was open.
        service.setStatus(.disabled)
        store.refreshBackgroundSupervision()
        #expect(!store.keepEnforcingWhenClosed)
        // A refused registration leaves the switch off and says why.
        service.setFails(true)
        store.keepEnforcingWhenClosed = true
        #expect(!store.keepEnforcingWhenClosed)
        #expect(store.backgroundSupervisionError == "Operation not permitted")
    }

    @Test func aHelperRegisteredEarlierIsShownAsOn() {
        let service = FakeSupervisionService()
        service.setStatus(.enabled)
        #expect(settings(service).keepEnforcingWhenClosed)
        #expect(service.status() == .enabled)  // reading the state changed nothing
    }
}
