import Testing
@testable import AppCore

@Suite struct BackendSelectionTests {
    @Test func defaultsToCLI() {
        #expect(BackendSelection(rawValue: "") == nil)
        #expect(BackendSelection(rawValue: "mock") == .mock)
    }
}
