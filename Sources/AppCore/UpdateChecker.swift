import Foundation
import Observation

/// Checks GitHub for newer releases of Container Desktop and of Apple's `container` runtime.
///
/// It only reads two public `releases/latest` endpoints and never downloads or installs anything. Automatic
/// checks run at most once per `automaticInterval` (the time of the last attempt is persisted, so a failed or
/// rate-limited check is not retried until the next day) and only while `SettingsStore.automaticUpdateChecks`
/// is on. A failed check is state for the Updates pane ("Could not check"), never an error banner.
@MainActor
@Observable
public final class UpdateChecker {
    /// UserDefaults keys.
    public enum Key {
        /// Time of the last check attempt (seconds since 1970).
        public static let lastCheck = "updates.lastCheck"
        /// Last known latest app release (JSON `ReleaseInfo`).
        public static let latestApp = "updates.latestApp"
        /// Last known latest runtime release (JSON `ReleaseInfo`).
        public static let latestRuntime = "updates.latestRuntime"
    }

    /// Minimum time between automatic checks: 24 hours.
    public static let automaticInterval: TimeInterval = 24 * 60 * 60

    /// The running app's version (`CFBundleShortVersionString`, or `dev` outside a bundle).
    public let installedAppVersion: String
    /// Newest known stable release of the app (remembered across launches).
    public private(set) var latestApp: ReleaseInfo?
    /// Newest known stable release of the runtime (remembered across launches).
    public private(set) var latestRuntime: ReleaseInfo?
    /// Why the last app check gave no answer; `nil` after a successful check or before any check.
    public private(set) var appFailure: UpdateCheckFailure?
    /// Why the last runtime check gave no answer.
    public private(set) var runtimeFailure: UpdateCheckFailure?
    /// A check is in flight.
    public private(set) var isChecking = false
    /// When the last check (automatic or manual) was attempted.
    public private(set) var lastChecked: Date?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let http: any HTTPFetching
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date

    /// - Parameters:
    ///   - settings: read for the automatic-check switch.
    ///   - http: the network; tests pass canned responses.
    ///   - defaults: where the throttle timestamp and last known releases are kept.
    ///   - installedAppVersion: defaults to the bundle's version.
    ///   - now: the clock; tests move it.
    public init(
        settings: SettingsStore, http: any HTTPFetching = URLSessionHTTPFetcher(), defaults: UserDefaults = .standard,
        installedAppVersion: String? = nil, now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.settings = settings
        self.http = http
        self.defaults = defaults
        self.now = now
        self.installedAppVersion = installedAppVersion ?? Diagnostics.appVersion
        let stamp = defaults.double(forKey: Key.lastCheck)
        lastChecked = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        latestApp = Self.load(Key.latestApp, from: defaults)
        latestRuntime = Self.load(Key.latestRuntime, from: defaults)
    }

    // MARK: Offers

    /// The app release to offer, when a stable release newer than the running app is known.
    public var appUpdate: ReleaseInfo? {
        guard let latestApp, latestApp.isNewer(than: installedAppVersion) else { return nil }
        return latestApp
    }

    /// The runtime release to offer for the given installed version (`nil` when unknown or up to date).
    public func runtimeUpdate(installed: String?) -> ReleaseInfo? {
        guard let latestRuntime, latestRuntime.isNewer(than: installed) else { return nil }
        return latestRuntime
    }

    /// Whether an automatic check would run now: the setting is on and 24 hours passed since the last attempt.
    public var isAutomaticCheckDue: Bool {
        guard settings.automaticUpdateChecks else { return false }
        guard let lastChecked else { return true }
        let elapsed = now().timeIntervalSince(lastChecked)
        // A timestamp in the future (clock moved back) must not block checks forever.
        return elapsed < 0 || elapsed >= Self.automaticInterval
    }

    // MARK: Checking

    /// The automatic path: checks only when `isAutomaticCheckDue`. Returns whether a check ran.
    @discardableResult
    public func checkIfDue() async -> Bool {
        guard isAutomaticCheckDue, !isChecking else { return false }
        await checkNow()
        return true
    }

    /// Runs `checkIfDue()` now and then hourly until the surrounding task is cancelled, so an app left open
    /// for days still notices a release within a day.
    public func runAutomaticChecks() async {
        while !Task.isCancelled {
            await checkIfDue()
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// The manual path ("Check Now"): always asks GitHub, for both products at once.
    public func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        // Stamp the attempt first: a check that fails still counts against the daily budget.
        let started = now()
        lastChecked = started
        defaults.set(started.timeIntervalSince1970, forKey: Key.lastCheck)

        let http = self.http
        async let appResult = ReleaseLookup.latest(.app, using: http)
        async let runtimeResult = ReleaseLookup.latest(.runtime, using: http)
        switch await appResult {
        case .success(let release):
            latestApp = release
            appFailure = nil
            Self.save(release, Key.latestApp, to: defaults)
        case .failure(let failure):
            appFailure = failure
        }
        switch await runtimeResult {
        case .success(let release):
            latestRuntime = release
            runtimeFailure = nil
            Self.save(release, Key.latestRuntime, to: defaults)
        case .failure(let failure):
            runtimeFailure = failure
        }
    }

    // MARK: Persistence

    private static func load(_ key: String, from defaults: UserDefaults) -> ReleaseInfo? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    private static func save(_ release: ReleaseInfo, _ key: String, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(release) { defaults.set(data, forKey: key) }
    }
}
