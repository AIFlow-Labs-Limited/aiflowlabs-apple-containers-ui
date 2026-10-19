import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

@MainActor
@Suite struct TaskCenterTests {
    @Test func consumesStreamIntoTask() async {
        let center = TaskCenter()
        var finished: [String] = []
        center.onFinish = { finished.append($0.title) }
        let stream = LineStream { c in
            c.yield(OutputLine("one"))
            c.yield(OutputLine("two", stream: .stderr))
            c.finish()
        }
        let task = center.run(title: "Demo", kind: .other, stream: stream)
        #expect(center.activeCount == 1)
        await task.wait()
        #expect(task.lines.map(\.text) == ["one", "two"])
        #expect(task.lines.last?.stream == .stderr)
        #expect(task.state == .succeeded)
        #expect(task.finishedAt != nil)
        #expect(center.activeCount == 0)
        #expect(finished == ["Demo"])
    }

    @Test func recordsFailure() async {
        let center = TaskCenter()
        let task = center.run(
            title: "Bad", kind: .pull,
            stream: LineStream { c in
                c.yield(OutputLine("start"))
                c.finish(
                    throwing: BackendError.commandFailed(
                        command: "container image pull x", exitCode: 1, message: "nope"))
            })
        await task.wait()
        #expect(task.state == .failed(.commandFailed(command: "container image pull x", exitCode: 1, message: "nope")))
    }

    @Test func cancelStopsTask() async {
        let center = TaskCenter()
        let task = center.run(
            title: "Slow", kind: .build, stream: MockBackend().buildImage(BuildSpec(contextDirectory: "/", tag: "x")))
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.wait()
        #expect(task.state == .cancelled)
    }

    @Test func keepsAtMostMaxRetained() async {
        let center = TaskCenter()
        center.maxRetained = 3
        for i in 0..<5 {
            await center.run(title: "t\(i)", kind: .other, stream: LineStream { $0.finish() }).wait()
        }
        #expect(center.tasks.count <= 4)
        #expect(center.tasks.first?.title == "t4")
    }
}

@MainActor
@Suite struct PollerTests {
    @Test func pausesWhenEngineStopped() async throws {
        let gate = PollingGate(engineRunning: false, interval: .milliseconds(20))
        var fired = 0
        let poller = Poller(gate: gate) { fired += 1 }
        poller.start()
        try await Task.sleep(for: .milliseconds(120))
        #expect(fired == 0)
        gate.engineRunning = true
        for _ in 0..<100 where fired < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(fired >= 2)
        poller.stop()
        #expect(!poller.isRunning)
    }

    @Test func pausesWhenAppInactive() async throws {
        let gate = PollingGate(engineRunning: true, appActive: false, interval: .milliseconds(20))
        var fired = 0
        let poller = Poller(gate: gate) { fired += 1 }
        poller.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fired == 0)
        poller.stopAll()
    }

    @Test func referenceCountedStop() {
        let poller = Poller(gate: PollingGate()) {}
        poller.start()
        poller.start()
        poller.stop()
        #expect(poller.isRunning)
        poller.stop()
        #expect(!poller.isRunning)
    }

    @Test func backoffDoublesAndCaps() {
        #expect(Poller.delay(base: .seconds(2), failures: 0) == .seconds(2))
        #expect(Poller.delay(base: .seconds(2), failures: 1) == .seconds(4))
        #expect(Poller.delay(base: .seconds(2), failures: 2) == .seconds(8))
        #expect(Poller.delay(base: .seconds(2), failures: 10) == .seconds(30))
    }
}

@MainActor
@Suite struct CommandPaletteTests {
    @Test func fuzzyScoring() {
        #expect(CommandPalette.score("pg", "postgres") != nil)
        #expect(CommandPalette.score("xyz", "postgres") == nil)
        #expect(CommandPalette.score("post", "postgres")! > CommandPalette.score("pst", "postgres")!)
        #expect(CommandPalette.score("db", "db")! > CommandPalette.score("db", "dbx")!)
        #expect(CommandPalette.score("se", "Start engine")! > CommandPalette.score("se", "Images") ?? Int.min)
    }

    @Test func resultsAndRecents() async {
        let model = TestSupport.model()
        await model.containers.refresh()
        let palette = model.palette
        let items = palette.items(for: model)
        #expect(items.contains { $0.action == .navigate(.containers, itemID: "db") })
        #expect(items.contains { $0.action == .startEngine })
        palette.query = "start eng"
        #expect(palette.results(in: items).first?.action == .startEngine)
        palette.query = "api"
        #expect(palette.results(in: items).first?.title == "api")
        palette.markUsed(items.first { $0.action == .openSettings }!)
        palette.query = ""
        #expect(palette.results(in: items).first?.action == .openSettings)
    }
}

@MainActor
@Suite struct SettingsAndTOMLTests {
    @Test func validatorAcceptsValidConfig() {
        let text = """
            # comment
            [container]
            cpus = 4
            memory = "8g"   # trailing comment

            [dns]
            domain = "test"
            list = [
              "a",
              "b",
            ]
            """
        #expect(TOMLValidator.validate(text).isEmpty)
    }

    @Test func validatorFlagsProblems() {
        #expect(TOMLValidator.validate("[container\ncpus = 4").first?.line == 1)
        #expect(TOMLValidator.validate("[a]\njust words").first?.message == "Expected “key = value”")
        #expect(TOMLValidator.validate("k = \"unterminated").first?.message == "Unterminated string")
        #expect(TOMLValidator.validate("[a]\nx = 1\n[a]").first?.message == "Duplicate section [a]")
        #expect(TOMLValidator.validate("k =").first?.message == "Missing value for “k”")
        #expect(TOMLValidator.validate("arr = [1,\n2").first?.message == "Unterminated array")
    }

    @Test func editorSetsAndReadsValues() {
        var text = "[dns]\ndomain = \"test\"\n"
        text = TOMLEditor.setting("cpus", to: "4", section: "container", in: text)
        #expect(TOMLEditor.value("cpus", section: "container", in: text) == "4")
        text = TOMLEditor.setting("cpus", to: "6", section: "container", in: text)
        #expect(TOMLEditor.value("cpus", section: "container", in: text) == "6")
        text = TOMLEditor.setting("memory", to: "\"8g\"", section: "container", in: text)
        #expect(TOMLEditor.stringValue("memory", section: "container", in: text) == "8g")
        #expect(TOMLEditor.stringValue("domain", section: "dns", in: text) == "test")
        text = TOMLEditor.setting("cpus", to: nil, section: "container", in: text)
        #expect(TOMLEditor.value("cpus", section: "container", in: text) == nil)
        #expect(TOMLValidator.validate(text).isEmpty)
    }

    @Test func settingsPersistAndClamp() {
        let defaults = TestSupport.defaults()
        let s = SettingsStore(defaults: defaults)
        #expect(s.pollingInterval == 2)
        #expect(s.menuBarEnabled)
        s.pollingInterval = 42
        #expect(s.pollingInterval == 10)
        s.showStoppedContainers = false
        s.appearance = .dark
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.pollingInterval == 10)
        #expect(reloaded.showStoppedContainers == false)
        #expect(reloaded.appearance == .dark)
    }

    @Test func saveConfigRejectsInvalid() async throws {
        // config.toml goes through SystemStore (SettingsStore's duplicate helpers were removed).
        let model = TestSupport.model()
        #expect(await model.system.saveConfigTOML("[oops") == false)
        #expect(await model.system.saveConfigTOML("[container]\ncpus = 2\n"))
        await model.system.loadConfigTOML()
        #expect(model.system.configTOML.contains("cpus = 2"))
    }
}
