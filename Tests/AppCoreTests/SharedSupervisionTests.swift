import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

/// One mock engine watched by two supervisors, as when the app and the background helper both run: each has its
/// own claim on the same lock files and reads the same state file.
@MainActor
struct SharedSupervisionHarness {
    let backend = MockBackend()
    let clock = FakeClock()
    let paths = SupervisionPaths(
        directory: FileManager.default.temporaryDirectory.appending(path: "cd-supervision-\(UUID().uuidString)"))
    let appClaim: EnforcementClaim
    let helperClaim: EnforcementClaim
    let app: RestartSupervisor
    let helper: RestartSupervisor

    init() async {
        let clock = clock
        let backend = backend
        await backend.setLatency(.zero)
        await backend.setClock { clock.now }
        let appClaim = EnforcementClaim(role: .app, paths: paths)
        let helperClaim = EnforcementClaim(role: .helper, paths: paths)
        self.appClaim = appClaim
        self.helperClaim = helperClaim
        var timing = RestartSupervisor.Timing()
        timing.initialDelay = 0
        app = RestartSupervisor(
            timing: timing, state: FileSupervisionState(url: paths.state), claim: { appClaim.hold() },
            now: { clock.now }
        ) { try await backend.startContainer($0) }
        helper = RestartSupervisor(
            timing: timing, state: FileSupervisionState(url: paths.state), claim: { helperClaim.hold() },
            now: { clock.now }
        ) { try await backend.startContainer($0) }
    }

    func add(_ id: String, policy: String, running: Bool = true) async {
        await backend.addContainer(id: id, labels: [AppLabel.restart: policy], running: running)
    }

    /// One look by each supervisor at the same list, a second apart, the app first.
    func tick() async {
        let list = (try? await backend.listContainers(includeStopped: true)) ?? []
        await app.observe(list)
        await helper.observe(list)
        clock.advance(1)
    }

    func starts(_ id: String) async -> Int { await backend.startCounts[id] ?? 0 }
    func cleanUp() { try? FileManager.default.removeItem(at: paths.directory) }
}

@MainActor
@Suite("Restart policies: the app and the background helper")
struct SharedSupervisionTests {
    // MARK: Locks

    @Test func aFileLockHasOneHolderAtATime() {
        let url = FileManager.default.temporaryDirectory.appending(path: "cd-lock-\(UUID().uuidString)/x.lock")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!FileLock.isLockedElsewhere(url))  // no file yet
        let first = FileLock(url: url)
        let second = FileLock(url: url)
        #expect(first.tryLock())
        #expect(first.tryLock())  // already held: still true
        #expect(!second.tryLock())
        #expect(FileLock.isLockedElsewhere(url))
        first.unlock()
        #expect(!first.isHeld)
        #expect(!FileLock.isLockedElsewhere(url))
        #expect(second.tryLock())
        #expect(!first.tryLock())
    }

    @Test func theAppHandsOverToTheHelperAndTakesBackWhenItIsGone() {
        let paths = SupervisionPaths(
            directory: FileManager.default.temporaryDirectory.appending(path: "cd-claim-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let app = EnforcementClaim(role: .app, paths: paths)
        let helper = EnforcementClaim(role: .helper, paths: paths)
        #expect(app.hold())
        // The helper starts: it announces itself, but the app still holds the enforcer lock.
        #expect(!helper.hold())
        #expect(app.isHeld && !helper.isHeld)
        // The app's next pass sees the helper and lets go; nobody enforces until the helper's next pass.
        #expect(!app.hold())
        #expect(!app.isHeld && !helper.isHeld)
        #expect(helper.hold())
        #expect(!app.hold())
        // The helper goes away (switched off, or its process ended): the app takes over again.
        helper.release()
        #expect(app.hold())
        #expect(!helper.isHeld)
    }

    @Test func twoHelpersNeverBothEnforce() {
        let paths = SupervisionPaths(
            directory: FileManager.default.temporaryDirectory.appending(path: "cd-claim-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.directory) }
        let first = EnforcementClaim(role: .helper, paths: paths)
        let second = EnforcementClaim(role: .helper, paths: paths)
        #expect(first.hold())
        #expect(!second.hold())
        first.release()
        #expect(second.hold())
    }

    // MARK: Shared state

    @Test func theStateFileIsSharedAndUpdatesDoNotLoseEachOther() {
        let url = FileManager.default.temporaryDirectory.appending(path: "cd-state-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let app = FileSupervisionState(url: url)
        let helper = FileSupervisionState(url: url)
        #expect(app.read() == SupervisionState())
        let stopped = Date(timeIntervalSince1970: 1_800_000_000)
        app.update { $0.stops["db"] = stopped }
        #expect(helper.read().stops == ["db": stopped])
        // Each side changes its own part; neither overwrites the other with what it read earlier.
        helper.update { $0.stops["cache"] = stopped }
        app.update { $0.engineStopRequested = stopped }
        helper.update { $0.stops["db"] = nil }
        #expect(app.read() == SupervisionState(stops: ["cache": stopped], engineStopRequested: stopped))
        // A damaged file reads as empty and is replaced by the next write.
        try? Data("not json".utf8).write(to: url)
        #expect(app.read() == SupervisionState())
        app.update { $0.stops["db"] = stopped }
        #expect(helper.read().stops == ["db": stopped])
    }

    @Test func stopsRecordedByAnEarlierVersionAreAdoptedOnce() {
        let url = FileManager.default.temporaryDirectory.appending(path: "cd-state-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let defaults = TestSupport.defaults()
        let stopped = Date(timeIntervalSince1970: 1_800_000_000)
        DefaultsSupervisionState(defaults).update { $0.stops["db"] = stopped }
        let file = FileSupervisionState(url: url)
        file.adoptStops(from: defaults)
        #expect(file.read().stops == ["db": stopped])
        file.update { $0.stops = [:] }
        file.adoptStops(from: defaults)  // the file exists now: nothing is brought back
        #expect(file.read().stops.isEmpty)
    }

    // MARK: Two supervisors, one engine

    @Test func aContainerIsRestartedOnceWhoeverEnforces() async {
        let h = await SharedSupervisionHarness()
        defer { h.cleanUp() }
        await h.add("db", policy: "always")
        await h.tick()  // the app claims first; the helper announces itself
        #expect(!h.app.isStandingDown && h.helper.isStandingDown)
        await h.backend.simulateExitIgnoringErrors("db")
        await h.tick()  // the app lets go and does nothing; the helper takes over and restarts it
        #expect(h.app.isStandingDown && !h.helper.isStandingDown)
        #expect(await h.starts("db") == 1)
        for _ in 0..<3 { await h.tick() }
        #expect(await h.starts("db") == 1)
        await h.backend.simulateExitIgnoringErrors("db")
        await h.tick()
        #expect(await h.starts("db") == 2)
        #expect(h.app.status(for: "db") == nil)
        #expect(h.helper.status(for: "db")?.restartCount == 2)
    }

    @Test func aStopMadeInTheAppIsRespectedByTheHelper() async throws {
        let h = await SharedSupervisionHarness()
        defer { h.cleanUp() }
        await h.add("db", policy: "always")
        await h.add("cache", policy: "unless-stopped")
        for _ in 0..<2 { await h.tick() }
        #expect(h.helper.isStandingDown == false)
        // What the Containers store does on Stop: record the intent, then stop.
        h.app.noteStopRequested(["db", "cache"])
        try await h.backend.stopContainer("db", timeoutSeconds: nil, signal: nil)
        try await h.backend.stopContainer("cache", timeoutSeconds: nil, signal: nil)
        for _ in 0..<5 { await h.tick() }
        #expect(await h.backend.startCounts.isEmpty)
        #expect(h.helper.isIntentionallyStopped("db") && h.app.isIntentionallyStopped("cache"))
        // Start in the app: supervised again, by the helper.
        try await h.backend.startContainer("db")
        h.app.noteStartRequested(["db"])
        await h.tick()
        await h.backend.simulateExitIgnoringErrors("db")
        await h.tick()
        #expect(await h.starts("db") == 2)
        #expect(await h.starts("cache") == 0)
    }

    @Test func takingOverIsNotALaunch() async throws {
        let h = await SharedSupervisionHarness()
        defer { h.cleanUp() }
        await h.add("db", policy: "always")
        await h.add("worker", policy: "always")
        for _ in 0..<2 { await h.tick() }  // the helper enforces
        h.app.noteStopRequested(["db"])
        try await h.backend.stopContainer("db", timeoutSeconds: nil, signal: nil)
        await h.tick()
        // The helper is switched off, and `worker` crashes before the app has looked again.
        h.helperClaim.release()
        await h.backend.simulateExitIgnoringErrors("worker")
        let list = try await h.backend.listContainers(includeStopped: true)
        await h.app.observe(list)
        #expect(!h.app.isStandingDown)
        // `always` comes back on a launch even after a stop from the app; a change of enforcer is not one.
        #expect(await h.starts("db") == 0)
        #expect(await h.starts("worker") == 1)
    }

    @Test func anEngineStopFromTheAppIsNotACrashForTheHelper() async throws {
        let h = await SharedSupervisionHarness()
        defer { h.cleanUp() }
        await h.add("db", policy: "always")
        for _ in 0..<2 { await h.tick() }
        h.app.engineWillStop()
        // The engine takes its containers down; the helper may still get a list that shows them stopped.
        await h.backend.simulateExitIgnoringErrors("db")
        for _ in 0..<5 { await h.tick() }
        #expect(await h.backend.startCounts.isEmpty)
        // The engine went down and came up again: the request is spent, and `always` is started.
        h.helper.engineWentDown()
        h.helper.engineCameUp()
        #expect(FileSupervisionState(url: h.paths.state).read().engineStopRequested == nil)
        await h.tick()
        #expect(await h.starts("db") == 1)
    }

    @Test func aFailedEngineStopLetsTheHelperCarryOn() async {
        let h = await SharedSupervisionHarness()
        defer { h.cleanUp() }
        await h.add("db", policy: "always")
        for _ in 0..<2 { await h.tick() }
        h.app.engineWillStop()
        h.app.engineStopFailed()
        await h.backend.simulateExitIgnoringErrors("db")
        await h.tick()
        #expect(await h.starts("db") == 1)
    }
}

extension MockBackend {
    /// `simulateExit` for tests that know the container exists.
    func simulateExitIgnoringErrors(_ id: String) { try? simulateExit(id) }
}
