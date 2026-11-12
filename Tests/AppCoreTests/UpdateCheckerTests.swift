import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

/// Canned GitHub: a response (or a thrown error) per feed, and a count of the requests made.
actor CannedHTTP: HTTPFetching {
    enum Answer: Sendable {
        case ok(String)
        case status(Int)
        case offline
    }

    private var answers: [ReleaseFeed: Answer]
    private(set) var requests: [URL] = []

    init(app: Answer, runtime: Answer) { answers = [.app: app, .runtime: runtime] }

    func set(_ feed: ReleaseFeed, _ answer: Answer) { answers[feed] = answer }

    func get(_ url: URL) async throws -> (data: Data, status: Int) {
        requests.append(url)
        let feed: ReleaseFeed = url == ReleaseFeed.app.latestReleaseAPI ? .app : .runtime
        switch answers[feed] ?? .offline {
        case .ok(let body): return (Data(body.utf8), 200)
        case .status(let code): return (Data(#"{"message":"nope"}"#.utf8), code)
        case .offline: throw URLError(.notConnectedToInternet)
        }
    }

    static func release(_ tag: String, repository: String, prerelease: Bool = false) -> Answer {
        .ok(
            """
            {"tag_name":"\(tag)","html_url":"https://github.com/\(repository)/releases/tag/\(tag)",
             "published_at":"2026-11-06T23:56:02Z","draft":false,"prerelease":\(prerelease),"assets":[]}
            """)
    }

    static func app(_ tag: String) -> Answer { release(tag, repository: ReleaseFeed.app.repository) }
    static func runtime(_ tag: String) -> Answer { release(tag, repository: ReleaseFeed.runtime.repository) }
}

/// A clock tests can move.
@MainActor
final class TestClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(hours: Double) { date += hours * 3600 }
}

@MainActor
@Suite struct UpdateCheckerTests {
    private func make(
        _ http: CannedHTTP, installed: String = "0.1.0", defaults: UserDefaults = TestSupport.defaults(),
        clock: TestClock = TestClock()
    ) -> (UpdateChecker, SettingsStore) {
        let settings = SettingsStore(defaults: defaults)
        let checker = UpdateChecker(
            settings: settings, http: http, defaults: defaults, installedAppVersion: installed,
            now: { clock.date })
        return (checker, settings)
    }

    @Test func offersNewerAppAndRuntime() async {
        let http = CannedHTTP(app: CannedHTTP.app("v0.2.0"), runtime: CannedHTTP.runtime("1.7.1"))
        let (checker, _) = make(http)
        #expect(checker.appUpdate == nil)
        #expect(checker.lastChecked == nil)
        await checker.checkNow()
        #expect(checker.appUpdate?.version == "0.2.0")
        #expect(
            checker.appUpdate?.pageURL.absoluteString
                == "https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui/releases/tag/v0.2.0")
        #expect(checker.runtimeUpdate(installed: "1.5.0")?.version == "1.7.1")
        #expect(checker.runtimeUpdate(installed: "1.7.1") == nil)
        #expect(checker.runtimeUpdate(installed: "1.8.0") == nil)
        #expect(checker.runtimeUpdate(installed: nil) == nil)
        #expect(checker.appFailure == nil && checker.runtimeFailure == nil)
        #expect(checker.lastChecked != nil)
        #expect(await http.requests.count == 2)
    }

    @Test func noOfferWhenUpToDateOrDevelopmentBuild() async {
        let http = CannedHTTP(app: CannedHTTP.app("v0.2.0"), runtime: CannedHTTP.runtime("1.7.1"))
        let (current, _) = make(http, installed: "0.2.0")
        await current.checkNow()
        #expect(current.appUpdate == nil)
        #expect(current.latestApp?.version == "0.2.0")
        let (dev, _) = make(http, installed: "dev")
        await dev.checkNow()
        #expect(dev.appUpdate == nil)
    }

    @Test func automaticCheckRunsAtMostOncePerDay() async {
        let http = CannedHTTP(app: CannedHTTP.app("v0.2.0"), runtime: CannedHTTP.runtime("1.7.1"))
        let clock = TestClock()
        let (checker, _) = make(http, clock: clock)
        #expect(await checker.checkIfDue())
        #expect(await http.requests.count == 2)
        #expect(await checker.checkIfDue() == false)
        clock.advance(hours: 23.9)
        #expect(await checker.checkIfDue() == false)
        #expect(await http.requests.count == 2)
        clock.advance(hours: 0.2)
        #expect(await checker.checkIfDue())
        #expect(await http.requests.count == 4)
    }

    @Test func throttleAndLastKnownReleasesSurviveRelaunch() async {
        let http = CannedHTTP(app: CannedHTTP.app("v0.2.0"), runtime: CannedHTTP.runtime("1.7.1"))
        let defaults = TestSupport.defaults()
        let clock = TestClock()
        let (first, _) = make(http, defaults: defaults, clock: clock)
        await first.checkIfDue()
        clock.advance(hours: 1)
        let (second, _) = make(http, defaults: defaults, clock: clock)
        #expect(second.lastChecked == first.lastChecked)
        #expect(second.appUpdate?.version == "0.2.0")
        #expect(second.latestRuntime?.version == "1.7.1")
        #expect(await second.checkIfDue() == false)
        #expect(await http.requests.count == 2)
    }

    @Test func failedCheckStillCountsAgainstTheDailyBudget() async {
        let http = CannedHTTP(app: .status(403), runtime: .status(429))
        let clock = TestClock()
        let (checker, _) = make(http, clock: clock)
        #expect(await checker.checkIfDue())
        #expect(checker.appFailure == .rateLimited)
        #expect(checker.runtimeFailure == .rateLimited)
        clock.advance(hours: 2)
        #expect(await checker.checkIfDue() == false)
        #expect(await http.requests.count == 2)
    }

    @Test func automaticChecksCanBeTurnedOffButCheckNowStillWorks() async {
        let http = CannedHTTP(app: CannedHTTP.app("v0.2.0"), runtime: CannedHTTP.runtime("1.7.1"))
        let defaults = TestSupport.defaults()
        let (checker, settings) = make(http, defaults: defaults)
        #expect(settings.automaticUpdateChecks)
        settings.automaticUpdateChecks = false
        #expect(SettingsStore(defaults: defaults).automaticUpdateChecks == false)
        #expect(checker.isAutomaticCheckDue == false)
        #expect(await checker.checkIfDue() == false)
        #expect(await http.requests.isEmpty)
        await checker.checkNow()
        #expect(await http.requests.count == 2)
        #expect(checker.appUpdate != nil)
    }

    @Test func clockMovedBackDoesNotBlockChecksForever() async {
        let http = CannedHTTP(app: CannedHTTP.app("v0.2.0"), runtime: CannedHTTP.runtime("1.7.1"))
        let clock = TestClock()
        let (checker, _) = make(http, clock: clock)
        await checker.checkNow()
        clock.advance(hours: -48)
        #expect(checker.isAutomaticCheckDue)
    }

    @Test func eachFailureModeIsQuietState() async {
        let cases: [(CannedHTTP.Answer, UpdateCheckFailure)] = [
            (.offline, .offline), (.status(403), .rateLimited), (.status(429), .rateLimited),
            (.status(404), .noRelease), (.status(500), .unexpectedStatus(500)),
            (.ok("<html>captive portal</html>"), .malformed), (.ok("{}"), .malformed),
            (.ok(#"{"tag_name":"nightly"}"#), .malformed), (.ok(#"{"tag_name":42}"#), .malformed),
        ]
        for (answer, expected) in cases {
            let http = CannedHTTP(app: answer, runtime: CannedHTTP.runtime("1.7.1"))
            let (checker, _) = make(http)
            await checker.checkNow()
            #expect(checker.appFailure == expected)
            #expect(checker.appUpdate == nil)
            // One feed failing does not hide the other.
            #expect(checker.runtimeFailure == nil)
            #expect(checker.latestRuntime?.version == "1.7.1")
            #expect(!expected.explanation.isEmpty)
        }
    }

    @Test func failureKeepsTheLastKnownReleaseAndClearsOnSuccess() async {
        let http = CannedHTTP(app: CannedHTTP.app("v0.2.0"), runtime: CannedHTTP.runtime("1.7.1"))
        let (checker, _) = make(http)
        await checker.checkNow()
        await http.set(.app, .offline)
        await checker.checkNow()
        #expect(checker.appFailure == .offline)
        #expect(checker.appUpdate?.version == "0.2.0")
        await http.set(.app, CannedHTTP.app("v0.3.0"))
        await checker.checkNow()
        #expect(checker.appFailure == nil)
        #expect(checker.appUpdate?.version == "0.3.0")
    }

    @Test func prereleasesAreNotOffered() async {
        let flagged = CannedHTTP.release("v0.2.0", repository: ReleaseFeed.app.repository, prerelease: true)
        let http = CannedHTTP(app: flagged, runtime: CannedHTTP.runtime("1.8.0-beta.1"))
        let (checker, _) = make(http)
        await checker.checkNow()
        #expect(checker.appUpdate == nil)
        #expect(checker.appFailure == .noRelease)
        #expect(checker.runtimeUpdate(installed: "1.5.0") == nil)
        #expect(checker.runtimeFailure == .noRelease)
    }

    @Test func releasePageMustBeOnGitHubInsideTheRepository() {
        let feed = ReleaseFeed.runtime
        let good = "https://github.com/apple/container/releases/tag/1.7.1"
        #expect(ReleaseLookup.trustedPage(good, feed: feed).absoluteString == good)
        for bad in [
            "https://evil.example/apple/container/releases/tag/1.7.1", "http://github.com/apple/container/releases/x",
            "https://github.com/someone/else/releases/tag/1.7.1", "javascript:alert(1)", "",
        ] {
            #expect(ReleaseLookup.trustedPage(bad, feed: feed) == feed.latestReleasePage)
        }
        #expect(ReleaseLookup.trustedPage(nil, feed: feed) == feed.latestReleasePage)
    }

    @Test func parsesRealGitHubShape() throws {
        // Trimmed from GET /repos/apple/container/releases/latest (2026-11).
        let body = """
            {"url":"https://api.github.com/repos/apple/container/releases/437182989",
             "html_url":"https://github.com/apple/container/releases/tag/1.7.1","id":437182989,
             "tag_name":"1.7.1","target_commitish":"main","name":"1.7.1","draft":false,"immutable":false,
             "prerelease":false,"created_at":"2026-11-06T22:37:30Z","published_at":"2026-11-06T23:56:02Z",
             "assets":[{"name":"container-1.7.1-installer-signed.pkg"}],"body":"notes","mentions_count":12}
            """
        let release = try ReleaseLookup.parse(Data(body.utf8), feed: .runtime).get()
        #expect(release.version == "1.7.1")
        #expect(release.publishedAt == Date(timeIntervalSince1970: 1_794_009_362))
        #expect(release.isNewer(than: "1.5.0"))
    }

    /// The only test that touches the network, and only on request:
    /// `CONTAINER_DESKTOP_LIVE_UPDATE_CHECK=1 swift test --filter liveGitHubAnswersParse`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_LIVE_UPDATE_CHECK"] == "1"))
    func liveGitHubAnswersParse() async throws {
        for feed in ReleaseFeed.allCases {
            let release = try await ReleaseLookup.latest(feed, using: URLSessionHTTPFetcher()).get()
            #expect(release.semanticVersion != nil)
            #expect(release.pageURL.host() == "github.com")
        }
    }

    @Test func modelCombinesEngineVersionWithLatestRelease() async {
        let http = CannedHTTP(app: CannedHTTP.app("v0.1.0"), runtime: CannedHTTP.runtime("1.7.1"))
        let defaults = TestSupport.defaults()
        let settings = SettingsStore(defaults: defaults)
        let checker = UpdateChecker(settings: settings, http: http, defaults: defaults, installedAppVersion: "0.1.0")
        let model = AppModel(
            backend: MockBackend(), settings: settings, buildsHistoryURL: TestSupport.historyURL(),
            observeAppActivation: false, updates: checker)
        #expect(model.installedRuntimeVersion == nil)
        #expect(model.runtimeCompatibility == .unknown)
        await model.refreshEngine()
        #expect(model.installedRuntimeVersion == Fixtures.cliVersion)
        #expect(model.runtimeCompatibility == .supported)
        #expect(model.isUpdateAvailable == false)
        await checker.checkNow()
        #expect(model.runtimeUpdate?.version == "1.7.1")
        #expect(model.isUpdateAvailable)
        #expect(model.updateSummary == "container 1.7.1 is available")
        #expect(Diagnostics.report(for: model).contains("Automatic update checks: true"))
    }
}
