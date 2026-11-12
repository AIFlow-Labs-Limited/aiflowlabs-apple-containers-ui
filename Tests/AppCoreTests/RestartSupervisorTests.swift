import ContainerKit
import ContainerKitMock
import Foundation
import Synchronization
import Testing

@testable import AppCore

/// A clock the test moves by hand; shared with the mock so container start dates agree with it.
final class FakeClock: Sendable {
    private let current = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

/// Exit codes the test pretends the runtime reports (the real one, CLI 1.5.0, reports none).
final class FakeExitCodes: Sendable {
    private let codes = Mutex<[String: Int32]>([:])
    func set(_ code: Int32, for id: String) { codes.withLock { $0[id] = code } }
    func code(for id: String) -> Int32? { codes.withLock { $0[id] } }
}

/// A mock engine with a supervisor on a fake clock. `tick()` is one poll: list the containers, hand them over.
@MainActor
struct RestartHarness {
    let backend = MockBackend()
    let clock = FakeClock()
    let defaults: UserDefaults
    let tasks = TaskCenter()
    let supervisor: RestartSupervisor
    let exitCodes = FakeExitCodes()

    init(defaults: UserDefaults = TestSupport.defaults(), enabled: Bool = true) async {
        self.defaults = defaults
        let clock = clock
        let backend = backend
        let exitCodes = exitCodes
        await backend.setLatency(.zero)
        await backend.setClock { clock.now }
        supervisor = RestartSupervisor(
            isEnabled: enabled, defaults: defaults, taskCenter: tasks, now: { clock.now },
            exitCode: { exitCodes.code(for: $0.id) }
        ) { try await backend.startContainer($0) }
    }

    /// A supervisor as after an app relaunch: same engine, same defaults, fresh memory.
    func relaunched() -> RestartSupervisor {
        let clock = clock
        let backend = backend
        return RestartSupervisor(defaults: defaults, taskCenter: tasks, now: { clock.now }) {
            try await backend.startContainer($0)
        }
    }

    func add(_ id: String, policy: String?, running: Bool = true) async {
        await backend.addContainer(id: id, labels: policy.map { [AppLabel.restart: $0] } ?? [:], running: running)
    }

    func tick(_ supervisor: RestartSupervisor? = nil, busy: Set<String> = []) async {
        let list = (try? await backend.listContainers(includeStopped: true)) ?? []
        await (supervisor ?? self.supervisor).observe(list, busy: busy)
    }

    func exit(_ id: String) async { try? await backend.simulateExit(id) }
    func starts(_ id: String) async -> Int { await backend.startCounts[id] ?? 0 }
    func isRunning(_ id: String) async -> Bool {
        await backend.containers.first { $0.id == id }?.isRunning ?? false
    }

    /// Lets the container exit, sees it, and reports how long the supervisor then waits before starting it:
    /// the first whole second at which a poll restarts it.
    func secondsUntilRestart(of id: String, limit: Int = 90) async -> Int? {
        let before = await starts(id)
        await exit(id)
        await tick()
        for second in 1...limit {
            clock.advance(1)
            await tick()
            if await starts(id) > before { return second }
        }
        return nil
    }
}

@MainActor
@Suite("Restart policies")
struct RestartSupervisorTests {
    @Test func backoffScheduleDoublesToSixtySeconds() {
        let timing = RestartSupervisor.Timing()
        #expect((1...9).map { timing.delay(beforeAttempt: $0) } == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        #expect(timing.delay(beforeAttempt: 500) == 60)
        #expect(timing.stableAfter == 30)
    }

    @Test func alwaysRestartsWithGrowingDelaysAndNeverInATightLoop() async {
        let h = await RestartHarness()
        await h.add("db", policy: "always")
        await h.tick()  // first look: running, nothing to do
        #expect(await h.starts("db") == 0)

        // It keeps crashing right after every start: 1 s, 2 s, 4 s … then 60 s for ever.
        var delays: [Int] = []
        for _ in 0..<9 { delays.append(await h.secondsUntilRestart(of: "db") ?? -1) }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60, 60])
        #expect(await h.starts("db") == 9)
        #expect(h.supervisor.status(for: "db")?.restartCount == 9)
        #expect(h.supervisor.status(for: "db")?.consecutiveAttempts == 9)
        #expect(h.supervisor.status(for: "db")?.gaveUp == false)
        #expect(h.supervisor.totalRestarts == 9)
    }

    @Test func nothingHappensBeforeTheDelayIsOver() async {
        let h = await RestartHarness()
        await h.add("db", policy: "always")
        await h.tick()
        await h.exit("db")
        await h.tick()
        #expect(h.supervisor.status(for: "db")?.nextAttempt == h.clock.now.addingTimeInterval(1))
        h.clock.advance(0.75)
        await h.tick()
        await h.tick()
        #expect(await h.starts("db") == 0)
        h.clock.advance(0.25)
        await h.tick()
        #expect(await h.starts("db") == 1)
        #expect(await h.isRunning("db"))
        // Polls in quick succession do not start it twice.
        await h.tick()
        await h.tick()
        #expect(await h.starts("db") == 1)
    }

    @Test func attemptCountStartsOverOnceTheContainerStayedUp() async {
        let h = await RestartHarness()
        await h.add("db", policy: "always")
        await h.tick()
        #expect(await h.secondsUntilRestart(of: "db") == 1)
        #expect(await h.secondsUntilRestart(of: "db") == 2)
        // Up for 29 s: still counted as the same crash loop.
        h.clock.advance(29)
        await h.tick()
        #expect(h.supervisor.status(for: "db")?.consecutiveAttempts == 2)
        #expect(await h.secondsUntilRestart(of: "db") == 4)
        // Up for 30 s: healthy again, the next crash is restarted after 1 s.
        h.clock.advance(30)
        await h.tick()
        #expect(h.supervisor.status(for: "db")?.consecutiveAttempts == 0)
        #expect(await h.secondsUntilRestart(of: "db") == 1)
        #expect(h.supervisor.status(for: "db")?.restartCount == 4)
    }

    @Test func onFailureStopsAfterItsLimit() async {
        let h = await RestartHarness()
        var gaveUp: [(String, Int)] = []
        h.supervisor.onGiveUp = { gaveUp.append(($0, $1)) }
        await h.add("job", policy: "on-failure:2")
        await h.tick()
        #expect(await h.secondsUntilRestart(of: "job") == 1)
        #expect(await h.secondsUntilRestart(of: "job") == 2)
        // Third exit in a row: the limit of two attempts is used up.
        #expect(await h.secondsUntilRestart(of: "job", limit: 200) == nil)
        #expect(await h.starts("job") == 2)
        #expect(!(await h.isRunning("job")))
        #expect(h.supervisor.status(for: "job")?.gaveUp == true)
        #expect(h.supervisor.status(for: "job")?.nextAttempt == nil)
        #expect(gaveUp.map(\.0) == ["job"])
        #expect(gaveUp.map(\.1) == [2])

        // Starting it by hand in the app gives it a fresh count.
        try? await h.backend.startContainer("job")
        h.supervisor.noteStartRequested(["job"])
        await h.tick()
        #expect(h.supervisor.status(for: "job")?.gaveUp == false)
        #expect(await h.secondsUntilRestart(of: "job") == 1)
        #expect(gaveUp.count == 1)
    }

    @Test func onFailureWithoutALimitKeepsGoingAndIsNotStartedOnLaunch() async {
        let h = await RestartHarness()
        await h.add("worker", policy: "on-failure")
        await h.add("old", policy: "on-failure", running: false)
        await h.tick()
        #expect(await h.starts("old") == 0)  // found stopped at launch: left alone
        for expected in [1, 2, 4, 8] { #expect(await h.secondsUntilRestart(of: "worker") == expected) }
        #expect(await h.starts("old") == 0)
    }

    @Test func onFailureUsesTheExitCodeWhenTheRuntimeGivesOne() async {
        let h = await RestartHarness()
        await h.add("ok", policy: "on-failure")
        await h.add("bad", policy: "on-failure")
        await h.tick()
        h.exitCodes.set(0, for: "ok")
        h.exitCodes.set(1, for: "bad")
        await h.exit("ok")
        #expect(await h.secondsUntilRestart(of: "bad") == 1)
        h.clock.advance(120)
        await h.tick()
        #expect(await h.starts("ok") == 0)  // exit 0 is not a failure
        #expect(await h.starts("bad") == 1)
        await h.tasks.tasks.first?.wait()
        #expect(h.tasks.tasks.map(\.title) == ["Restart bad (exit 1), attempt 1"])
        // `always` restarts on a clean exit too.
        await h.add("svc", policy: "always")
        await h.tick()
        h.exitCodes.set(0, for: "svc")
        #expect(await h.secondsUntilRestart(of: "svc") == 1)
    }

    @Test func containersWithoutAPolicyAreNeverStarted() async {
        let h = await RestartHarness()
        await h.add("plain", policy: nil)
        await h.add("explicit-no", policy: "no")
        await h.add("garbage", policy: "sometimes")
        await h.add("plain-stopped", policy: nil, running: false)
        await h.tick()
        for id in ["plain", "explicit-no", "garbage"] { await h.exit(id) }
        for _ in 0..<5 {
            h.clock.advance(100)
            await h.tick()
        }
        // Not one start, on this mock or the fixtures it was seeded with.
        #expect(await h.backend.startCounts.isEmpty)
        #expect(h.supervisor.status(for: "plain") == nil)
        #expect(h.tasks.tasks.isEmpty)
    }

    @Test func everyRestartIsAnActivityEntry() async {
        let h = await RestartHarness()
        await h.add("db", policy: "unless-stopped")
        await h.tick()
        _ = await h.secondsUntilRestart(of: "db")
        _ = await h.secondsUntilRestart(of: "db")
        for task in h.tasks.tasks { await task.wait() }
        #expect(h.tasks.tasks.map(\.title) == ["Restart db, attempt 2", "Restart db, attempt 1"])
        #expect(h.tasks.tasks.allSatisfy { $0.state == .succeeded })
        #expect(
            h.tasks.tasks.last?.lines.map(\.text) == [
                "db stopped and has the restart policy “unless-stopped”. Starting it again.", "db is running.",
            ])
    }

    @Test func aStartThatFailsCountsAsAnAttemptAndIsRetriedWithBackoff() async {
        let h = await RestartHarness()
        await h.add("db", policy: "always")
        await h.add("job", policy: "on-failure:2")
        await h.tick()
        await h.backend.setStartFails(true, for: "db")
        await h.backend.setStartFails(true, for: "job")
        await h.exit("db")
        await h.exit("job")
        await h.tick()
        var attemptTimes: [Int] = []
        for second in 1...70 {
            h.clock.advance(1)
            let before = h.supervisor.status(for: "db")?.consecutiveAttempts ?? 0
            await h.tick()
            if (h.supervisor.status(for: "db")?.consecutiveAttempts ?? 0) > before { attemptTimes.append(second) }
        }
        // Attempts at 1 s, then 2, 4, 8, 16, 32 s after the previous failure.
        #expect(attemptTimes == [1, 3, 7, 15, 31, 63])
        #expect(h.supervisor.status(for: "db")?.restartCount == 0)
        #expect(h.supervisor.status(for: "job")?.gaveUp == true)
        #expect(h.supervisor.status(for: "job")?.consecutiveAttempts == 2)
        for task in h.tasks.tasks { await task.wait() }
        #expect(h.tasks.tasks.contains { $0.title == "Restart db, attempt 1" && $0.state != .succeeded })
        // Once starting works again, it comes back.
        await h.backend.setStartFails(false, for: "db")
        h.clock.advance(60)
        await h.tick()
        #expect(await h.isRunning("db"))
        #expect(h.supervisor.status(for: "db")?.restartCount == 1)
    }
}
