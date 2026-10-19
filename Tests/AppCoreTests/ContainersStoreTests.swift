import Foundation
import Testing
import ContainerKit
import ContainerKitMock
@testable import AppCore

@MainActor
@Suite struct ContainersStoreTests {
    let gate = PollingGate(engineRunning: true)

    @Test func refreshLoadsFixtures() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        #expect(store.items.count >= 4)
        #expect(store.items.contains { $0.id == "db" })
        #expect(store.lastError == nil)
        #expect(!store.isLoading)
    }

    @Test func filtersStoppedAndSearch() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        store.showStopped = false
        #expect(store.filtered.allSatisfy { $0.isRunning })
        store.showStopped = true
        store.searchText = "postgres"
        #expect(store.filtered.map(\.id) == ["db"])
    }

    @Test func stopStartDeleteMutate() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        await store.stop(["db"])
        #expect(store.container(id: "db")?.isRunning == false)
        await store.start(["db"])
        #expect(store.container(id: "db")?.isRunning == true)
        await store.delete(["old-job"])
        #expect(store.container(id: "old-job") == nil)
        #expect(store.lastError == nil)
    }

    @Test func deletingRunningWithoutForceCapturesError() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        await store.delete(["db"], force: false)
        guard case .commandFailed = store.lastError else { Issue.record("expected commandFailed, got \(String(describing: store.lastError))"); return }
        #expect(store.container(id: "db") != nil)
    }

    @Test func errorsLandInLastError() async {
        let store = ContainersStore(backend: FailingBackend(error: .systemNotRunning), gate: gate)
        await store.refresh()
        #expect(store.lastError == .systemNotRunning)
        #expect(store.items.isEmpty)
    }

    @Test func cpuPercentFromTwoSamples() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        let t0 = Date()
        await store.refreshStats(now: t0)
        #expect(store.cpuPercent.isEmpty) // one sample is not enough
        await store.refreshStats(now: t0.addingTimeInterval(2))
        #expect(!store.cpuPercent.isEmpty)
        #expect(store.cpuPercent.values.allSatisfy { $0 > 0 })
        #expect(store.totalCPUPercent > 0)
        #expect(store.totalMemoryBytes > 0)
    }

    @Test func unexpectedExitIsReported() async {
        let backend = MockBackend()
        let store = ContainersStore(backend: backend, gate: gate)
        var exited: [String] = []
        store.onUnexpectedExit = { exited.append($0.id) }
        await store.refresh()
        try? await backend.stopContainer("db", timeoutSeconds: nil, signal: nil) // stopped behind the store's back
        await store.stop(["api"]) // user-initiated: not reported
        #expect(exited == ["db"])
    }

    /// A poll that lands while a slow stop is still in flight must not clear the expectation (regression: the
    /// old `defer { expectedStops.removeAll() }` turned every slow stop into an "exited unexpectedly" alert).
    @Test func interleavedSlowStopIsNotReportedAsUnexpected() async throws {
        let backend = MockBackend()
        let store = ContainersStore(backend: backend, gate: gate)
        var exited: [String] = []
        store.onUnexpectedExit = { exited.append($0.id) }
        await store.refresh()
        await backend.setLatency(.milliseconds(400))
        let stopping = Task { await store.stop(["db"]) }
        try await Task.sleep(for: .milliseconds(50))          // stop is now in flight
        await backend.setLatency(.zero)
        await store.refresh()                                  // poll #1: db still running
        #expect(store.isExpectingStop("db"))
        await backend.markStopped("db")                       // engine reports it stopped before the CLI returns
        await store.refresh()                                  // poll #2: db seen stopped
        #expect(!store.isExpectingStop("db"))
        _ = await stopping.value
        #expect(exited.isEmpty)
    }

    @Test func expectedStopExpiresAfterTTL() async {
        let backend = MockBackend()
        let store = ContainersStore(backend: backend, gate: gate)
        var exited: [String] = []
        store.onUnexpectedExit = { exited.append($0.id) }
        var clock = Date(timeIntervalSince1970: 1_000)
        store.now = { clock }
        await store.refresh()
        // Kill fails (unknown id is skipped, db is marked) — simulate by marking via a failing kill on a stopped backend:
        await backend.setSystemRunning(false)
        await store.kill(["db"])
        await backend.setSystemRunning(true)
        #expect(store.isExpectingStop("db"))
        clock = clock.addingTimeInterval(ContainersStore.expectedStopTTL + 1)
        await backend.markStopped("db")                       // crashes much later: that IS unexpected
        await store.refresh()
        #expect(exited == ["db"])
        #expect(!store.isExpectingStop("db"))
    }

    @Test func bulkStopContinuesPastAFailingID() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        let result = await store.stop(["db", "nope", "api"])
        #expect(result.succeeded == ["db", "api"])
        #expect(result.failed.map(\.id) == ["nope"])
        #expect(store.container(id: "db")?.isRunning == false)
        #expect(store.container(id: "api")?.isRunning == false)
        #expect(store.lastError != nil)
        #expect(result.summary(verb: "Stopped", noun: "containers").hasPrefix("Stopped 2 of 3 containers; failed: nope"))
    }

    @Test func bulkDeleteReportsEveryFailure() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        let result = await store.delete(["x1", "old-job", "x2"], force: false)
        #expect(result.succeeded == ["old-job"])
        #expect(result.failed.map(\.id) == ["x1", "x2"])
        #expect(store.container(id: "old-job") == nil)
        guard case .other(let text) = store.lastError else { Issue.record("expected combined error"); return }
        #expect(text.contains("x1") && text.contains("x2"))
    }

    @Test func restartContinuesAfterAFailure() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        let result = await store.restart(["missing", "old-job"])
        #expect(result.succeeded == ["old-job"])
        #expect(store.container(id: "old-job")?.isRunning == true)
    }

    @Test func forceDeleteOfRunningIsAnExpectedStop() async {
        let backend = MockBackend()
        let store = ContainersStore(backend: backend, gate: gate)
        var exited: [String] = []
        store.onUnexpectedExit = { exited.append($0.id) }
        await store.refresh()
        let result = await store.delete(["db", "old-job"], force: true)
        #expect(result.allSucceeded)
        #expect(store.container(id: "db") == nil && store.container(id: "old-job") == nil)
        #expect(exited.isEmpty)
    }

    @Test func pruneLeavesSystemManagedContainers() async {
        let backend = MockBackend()
        await backend.addSystemManagedStopped("buildkit")
        let store = ContainersStore(backend: backend, gate: gate)
        await store.refresh()
        #expect(store.container(id: "buildkit")?.isSystemManaged == true)
        let result = await store.prune()
        #expect(result.succeeded == ["old-job"])
        #expect(store.container(id: "buildkit") != nil)
        #expect(store.container(id: "old-job") == nil)
    }

    @Test func statsHistoryIsFedByRefreshStats() async {
        let store = ContainersStore(backend: MockBackend(), gate: gate)
        await store.refresh()
        let t0 = Date()
        await store.refreshStats(now: t0)
        await store.refreshStats(now: t0.addingTimeInterval(2))
        #expect(store.statsHistory.points(for: "db").count == 2)
        #expect((store.statsHistory.latest(for: "db")?.cpuPercent ?? 0) > 0)
    }
}

@MainActor
@Suite struct ContainerHelpersTests {
    @Test func masksSensitiveEnvironment() {
        let env = ["PATH=/usr/bin", "API_TOKEN=abc", "DB_PASSWORD=", "SECRET_KEY", "aws_secret_access_key=xyz"]
        #expect(EnvironmentVariable.masked(env) == ["PATH=/usr/bin", "API_TOKEN=…", "DB_PASSWORD=", "SECRET_KEY",
                                                    "aws_secret_access_key=…"])
        #expect(EnvironmentVariable.containsSecrets(env))
        #expect(!EnvironmentVariable.containsSecrets(["PATH=/usr/bin", "TOKEN="]))
    }

    @Test func runCommandLineMasksOnlyWhenAsked() {
        var spec = RunSpec(image: "alpine")
        spec.environment = ["API_TOKEN=s3cret", "MODE=dev"]
        #expect(!spec.commandLineString(maskSecrets: true).contains("s3cret"))
        #expect(spec.commandLineString(maskSecrets: true).contains("MODE=dev"))
        #expect(spec.commandLineString(maskSecrets: false).contains("s3cret"))
    }

    @Test func validatesCustomShell() {
        for ok in ["/bin/ash", "sh", "bash", "/usr/local/bin/fish"] { #expect(ContainerShell.validationError(ok) == nil, "\(ok)") }
        for bad in ["", "sh|id", "sh>~/.zshrc", "/bin/a*", "bash -l", "python", "$(id)", "sh;rm", "/bin/", "~/sh"] {
            #expect(ContainerShell.validationError(bad) != nil, "\(bad)")
        }
    }

    @Test func quotingSurvivesShRoundTrip() throws {
        let words = ["container", "exec", "-it", "x", "sh|id", "a b", "it's", "*", "~", "$HOME", "#c", "(x)", ";", "&", "<", ">", "?"]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s\\n' " + ShellQuote.join(words)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(out.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init) == words)
    }
}

extension MockBackend {
    func setLatency(_ value: Duration) { latency = value }
    func setSystemRunning(_ value: Bool) { systemRunning = value }
    func markStopped(_ id: String) {
        if let i = containers.firstIndex(where: { $0.id == id }) { containers[i].status = Container.Status(state: .stopped) }
    }
    func addSystemManagedStopped(_ id: String) {
        guard var c = containers.first(where: { $0.id == "old-job" }) else { return }
        c.id = id
        c.configuration.id = id
        c.configuration.labels[ResourceLabel.role] = ResourceLabel.Role.builder
        containers.append(c)
    }
}
