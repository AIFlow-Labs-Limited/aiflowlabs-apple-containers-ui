import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

@MainActor
@Suite struct AppModelTests {
    @Test func engineRunningWithMock() async {
        let model = TestSupport.model()
        #expect(model.engine == .checking)
        await model.refreshEngine()
        #expect(model.engine.isRunning)
        #expect(model.gate.engineRunning)
    }

    @Test func stopAndStartEngine() async {
        let model = TestSupport.model()
        await model.refreshEngine()
        await model.stopEngine()
        #expect(model.engine == .stopped)
        #expect(!model.gate.engineRunning)
        await model.startEngine()
        #expect(model.engine.isRunning)
    }

    @Test func unsupportedBackendShowsErrorNotSpinner() async {
        let model = TestSupport.model(FailingBackend(error: .unsupported(feature: "systemStatus()", reason: "stub")))
        await model.refreshEngine()
        guard case .error(let e) = model.engine else { Issue.record("expected .error, got \(model.engine)"); return }
        #expect(e == .unsupported(feature: "systemStatus()", reason: "stub"))
        #expect(model.recentErrors.count == 1)
    }

    @Test func notInstalledBackend() async {
        let model = TestSupport.model(UnavailableBackend(searchedPaths: ["/nope/container"]))
        if case .notInstalled = model.engine {} else { Issue.record("expected .notInstalled, got \(model.engine)") }
    }

    @Test func navigationDeepLink() {
        let model = TestSupport.model()
        model.navigation.open(.containers, select: "db")
        #expect(model.navigation.section == .containers)
        #expect(model.navigation.consumeSelection(for: .containers) == "db")
        #expect(model.navigation.consumeSelection(for: .containers) == nil)
    }

    @Test func diagnosticsMentionsBackendAndSettings() async {
        let model = TestSupport.model()
        await model.refreshEngine()
        let report = Diagnostics.report(for: model)
        #expect(report.contains("Mock"))
        #expect(report.contains("Polling interval"))
        #expect(report.contains("running"))
    }

    @Test func pollingIntervalFlowsToGate() {
        let model = TestSupport.model()
        model.settings.pollingInterval = 5
        #expect(model.gate.interval == .seconds(5))
    }
}
