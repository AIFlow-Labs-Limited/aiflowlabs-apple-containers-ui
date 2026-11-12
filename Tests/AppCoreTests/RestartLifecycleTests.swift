import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

/// Stops made in the app, app launches, the engine going down and up, deleted containers, the global switch.
@MainActor
@Suite("Restart policies: stops, launches and the engine")
struct RestartLifecycleTests {
    @Test func aStopFromTheAppIsNotUndone() async {
        let h = await RestartHarness()
        await h.add("always", policy: "always")
        await h.add("unless", policy: "unless-stopped")
        await h.add("failure", policy: "on-failure")
        await h.tick()
        let ids = ["always", "unless", "failure"]
        h.supervisor.noteStopRequested(ids)
        for id in ids { try? await h.backend.stopContainer(id, timeoutSeconds: nil, signal: nil) }
        for _ in 0..<6 {
            h.clock.advance(45)
            await h.tick()
        }
        #expect(await h.backend.startCounts.isEmpty)
        #expect(ids.allSatisfy { h.supervisor.isIntentionallyStopped($0) })
        #expect(h.supervisor.status(for: "always")?.nextAttempt == nil)
    }

    @Test func intentionalStopsSurviveARelaunch() async {
        let h = await RestartHarness()
        await h.add("always", policy: "always")
        await h.add("unless", policy: "unless-stopped")
        await h.add("failure", policy: "on-failure:3")
        await h.add("crashed", policy: "unless-stopped")
        await h.tick()
        let stopped = ["always", "unless", "failure"]
        h.supervisor.noteStopRequested(stopped)
        for id in stopped { try? await h.backend.stopContainer(id, timeoutSeconds: nil, signal: nil) }
        await h.tick()
        await h.exit("crashed")  // goes down while the app is not looking (quit, reboot)

        // The app is launched again: same defaults, nothing remembered in memory.
        let relaunched = h.relaunched()
        #expect(relaunched.isIntentionallyStopped("unless"))
        h.clock.advance(3600)
        await h.tick(relaunched)
        // `always` comes back on launch even though it was stopped by hand, as in Docker.
        #expect(await h.starts("always") == 1)
        #expect(!relaunched.isIntentionallyStopped("always"))
        // `unless-stopped` stopped by hand stays down; the one that went down on its own comes back.
        #expect(await h.starts("unless") == 0)
        #expect(await h.starts("crashed") == 1)
        // `on-failure` is never started on launch.
        #expect(await h.starts("failure") == 0)
        for _ in 0..<4 {
            h.clock.advance(100)
            await h.tick(relaunched)
        }
        #expect(await h.backend.startCounts == ["always": 1, "crashed": 1])
        for task in h.tasks.tasks { await task.wait() }
        #expect(
            Set(h.tasks.tasks.map(\.title)) == [
                "Start always (restart policy always)", "Start crashed (restart policy unless-stopped)",
            ])
        // A launch start is not a restart.
        #expect(relaunched.status(for: "always")?.restartCount == 0)
    }

    @Test func startingItAgainInTheAppPutsItBackUnderSupervision() async {
        let h = await RestartHarness()
        await h.add("db", policy: "unless-stopped")
        await h.tick()
        h.supervisor.noteStopRequested(["db"])
        try? await h.backend.stopContainer("db", timeoutSeconds: nil, signal: nil)
        await h.tick()
        h.clock.advance(10)
        try? await h.backend.startContainer("db")
        h.supervisor.noteStartRequested(["db"])
        #expect(!h.supervisor.isIntentionallyStopped("db"))
        await h.tick()
        #expect(await h.secondsUntilRestart(of: "db") == 1)
    }

    @Test func aStartFromATerminalAlsoClearsTheMark() async {
        let h = await RestartHarness()
        await h.add("db", policy: "unless-stopped")
        await h.tick()
        h.supervisor.noteStopRequested(["db"])
        try? await h.backend.stopContainer("db", timeoutSeconds: nil, signal: nil)
        await h.tick()
        h.clock.advance(10)
        try? await h.backend.startContainer("db")  // `container start db` typed in a terminal
        await h.tick()
        #expect(!h.supervisor.isIntentionallyStopped("db"))
        #expect(await h.secondsUntilRestart(of: "db") == 1)
    }

    @Test func aStaleListDoesNotClearAFreshStopMark() async {
        let h = await RestartHarness()
        await h.add("db", policy: "always")
        await h.tick()
        let before = (try? await h.backend.listContainers(includeStopped: true)) ?? []
        h.clock.advance(5)
        h.supervisor.noteStopRequested(["db"])
        try? await h.backend.stopContainer("db", timeoutSeconds: nil, signal: nil)
        // A list fetched before the stop arrives late: "running", but started before the mark.
        await h.supervisor.observe(before)
        #expect(h.supervisor.isIntentionallyStopped("db"))
        h.clock.advance(5)
        await h.tick()
        h.clock.advance(5)
        await h.tick()
        #expect(await h.starts("db") == 0)
    }

    @Test func containersWithAnActionInFlightAreSkipped() async {
        let h = await RestartHarness()
        await h.add("db", policy: "always")
        await h.tick()
        await h.exit("db")
        await h.tick(busy: ["db"])
        h.clock.advance(5)
        await h.tick(busy: ["db"])
        #expect(await h.starts("db") == 0)
        await h.tick()
        h.clock.advance(1)
        await h.tick()
        #expect(await h.starts("db") == 1)
    }

    @Test func launchStartsAlwaysAndUnlessStoppedOnly() async {
        let h = await RestartHarness()
        await h.add("always", policy: "always", running: false)
        await h.add("unless", policy: "unless-stopped", running: false)
        await h.add("failure", policy: "on-failure", running: false)
        await h.add("plain", policy: nil, running: false)
        await h.add("none", policy: "no", running: false)
        await h.tick()
        #expect(await h.backend.startCounts == ["always": 1, "unless": 1])
        // If one of them exits straight away, it is restarted with backoff like any other.
        #expect(await h.secondsUntilRestart(of: "always") == 1)
        #expect(await h.secondsUntilRestart(of: "always") == 2)
    }

    @Test func engineStopIsNotACrashAndEngineStartBringsStacksBack() async {
        let h = await RestartHarness()
        await h.add("always", policy: "always")
        await h.add("unless", policy: "unless-stopped")
        await h.add("handStopped", policy: "unless-stopped")
        await h.add("plain", policy: nil)
        await h.tick()
        h.supervisor.noteStopRequested(["handStopped"])
        try? await h.backend.stopContainer("handStopped", timeoutSeconds: nil, signal: nil)
        await h.tick()

        // The app stops the engine: everything goes down with it.
        h.supervisor.engineWillStop()
        for id in ["always", "unless", "plain"] { await h.exit(id) }
        for _ in 0..<3 {
            h.clock.advance(30)
            await h.tick()
        }
        #expect(await h.backend.startCounts.isEmpty)

        // The engine is back (Start button, or the Mac rebooted and the app was launched).
        h.supervisor.engineCameUp()
        await h.tick()
        #expect(await h.backend.startCounts == ["always": 1, "unless": 1])
        #expect(h.supervisor.isIntentionallyStopped("handStopped"))
    }

    @Test func anEngineThatWentAwayIsNotCountedAsAFailedAttempt() async throws {
        let h = await RestartHarness()
        await h.add("db", policy: "on-failure:1")
        await h.tick()
        await h.exit("db")
        await h.tick()
        // Stopped from a terminal: the app only finds out when the start fails.
        try await h.backend.systemStop()
        let stale = [try #require(await h.backend.containers.first { $0.id == "db" })]
        h.clock.advance(1)
        await h.supervisor.observe(stale)
        #expect(h.supervisor.status(for: "db")?.consecutiveAttempts == 0)
        #expect(h.supervisor.status(for: "db")?.gaveUp == false)
        #expect(h.tasks.tasks.isEmpty)  // no "restart failed" noise for an engine that is simply off
        // Suspended until the engine is back.
        h.clock.advance(100)
        await h.supervisor.observe(stale)
        try await h.backend.systemStart()
        h.supervisor.engineCameUp()
        await h.tick()
        #expect(await h.starts("db") == 0)  // on-failure is not started on launch
        // A status hiccup, on the other hand, just carries on where it was.
        h.supervisor.engineWentDown()
        h.supervisor.resume()
        await h.add("svc", policy: "always")
        await h.tick()
        #expect(await h.secondsUntilRestart(of: "svc") == 1)
    }

    @Test func deletedContainersAreForgotten() async throws {
        let h = await RestartHarness()
        await h.add("db", policy: "always")
        await h.add("cache", policy: "unless-stopped")
        await h.tick()
        await h.exit("db")
        await h.tick()
        h.supervisor.noteStopRequested(["cache"])
        try await h.backend.deleteContainer("db", force: true)
        try await h.backend.deleteContainer("cache", force: true)
        h.clock.advance(5)
        await h.tick()
        #expect(h.supervisor.status(for: "db") == nil)
        #expect(!h.supervisor.isIntentionallyStopped("cache"))
        #expect(await h.backend.startCounts.isEmpty)
        #expect(h.tasks.tasks.isEmpty)
        // The mark is gone from disk too: a new container of the same name is supervised normally.
        #expect((h.defaults.dictionary(forKey: RestartSupervisor.intentionalStopsKey) ?? [:]).isEmpty)
        await h.add("cache", policy: "unless-stopped")
        await h.tick()
        #expect(await h.secondsUntilRestart(of: "cache") == 1)
    }

    @Test func aMarkOlderThanTheContainerBelongsToAnEarlierOne() async {
        let h = await RestartHarness()
        h.supervisor.noteStopRequested(["db"])  // left over from a container deleted while the app was closed
        h.clock.advance(60)
        await h.add("db", policy: "unless-stopped", running: false)
        await h.tick()
        #expect(await h.starts("db") == 1)
        #expect(!h.supervisor.isIntentionallyStopped("db"))
    }

    @Test func theGlobalSwitchTurnsEverythingOff() async {
        let h = await RestartHarness(enabled: false)
        await h.add("db", policy: "always")
        await h.add("down", policy: "always", running: false)
        await h.tick()
        await h.exit("db")
        for _ in 0..<4 {
            h.clock.advance(30)
            await h.tick()
        }
        #expect(await h.backend.startCounts.isEmpty)
        // Switching it on is like a launch: stopped `always` containers start.
        h.supervisor.isEnabled = true
        await h.tick()
        #expect(await h.backend.startCounts == ["db": 1, "down": 1])
        h.supervisor.isEnabled = false
        await h.exit("db")
        h.clock.advance(30)
        await h.tick()
        #expect(await h.starts("db") == 1)
    }

    // MARK: Wired into the app

    @Test func stopsInTheContainersStoreAreRemembered() async {
        let backend = MockBackend()
        await backend.setLatency(.zero)
        await backend.addContainer(id: "db", labels: [AppLabel.restart: "always"])
        await backend.addContainer(id: "plain")
        let model = TestSupport.model(backend)
        model.restarts.timing.initialDelay = 0
        await model.containers.poller.fireNow()
        #expect(model.containers.container(id: "db")?.restartPolicy == .always)

        // A crash is repaired by the poll that follows it.
        try? await backend.simulateExit("db")
        await model.containers.poller.fireNow()
        await model.containers.poller.fireNow()
        #expect(await backend.startCounts == ["db": 1])
        #expect(model.restarts.status(for: "db")?.restartCount == 1)
        #expect(model.taskCenter.tasks.contains { $0.title == "Restart db, attempt 1" })

        // Stop and Kill in the app are not.
        await model.containers.poller.fireNow()
        await model.containers.stop(["db", "plain"])
        #expect(model.restarts.isIntentionallyStopped("db"))
        #expect(!model.restarts.isIntentionallyStopped("plain"))  // no policy: nothing to remember
        for _ in 0..<3 { await model.containers.poller.fireNow() }
        #expect(await backend.startCounts == ["db": 1])

        // Start in the app clears the mark; Restart keeps it supervised.
        await model.containers.start(["db"])
        #expect(!model.restarts.isIntentionallyStopped("db"))
        await model.containers.restart(["db"])
        #expect(!model.restarts.isIntentionallyStopped("db"))
        await model.containers.poller.fireNow()
        await model.containers.kill(["db"])
        #expect(model.restarts.isIntentionallyStopped("db"))
        for _ in 0..<3 { await model.containers.poller.fireNow() }
        #expect(model.containers.container(id: "db")?.isRunning == false)

        // Deleting forgets it, one look later: a mark younger than the previous look may belong to a container
        // that is not in the list yet.
        await model.containers.delete(["db"], force: true)
        await model.containers.poller.fireNow()
        await model.containers.poller.fireNow()
        #expect(!model.restarts.isIntentionallyStopped("db"))
    }

    @Test func stoppingTheEngineFromTheAppSuspendsSupervision() async {
        let backend = MockBackend()
        await backend.setLatency(.zero)
        await backend.addContainer(id: "db", labels: [AppLabel.restart: "always"])
        let model = TestSupport.model(backend)
        model.restarts.timing.initialDelay = 0
        await model.refreshEngine()
        await model.containers.poller.fireNow()
        await model.stopEngine()
        try? await backend.simulateExit("db")
        // Even a list that still arrives is ignored while the engine is down.
        let list = await backend.containers
        await model.restarts.observe(list)
        await model.restarts.observe(list)
        #expect(await backend.startCounts.isEmpty)
        await model.startEngine()
        // The engine coming up also reloads every list; the first poll whose own list lands does the starting.
        for _ in 0..<50 where await backend.startCounts.isEmpty {
            await model.containers.poller.fireNow()
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(await backend.startCounts == ["db": 1])
    }
}
