import Foundation
import Observation
import ServiceManagement
import ContainerKit

/// App preferences. Persisted in `UserDefaults` under the same keys `@AppStorage` would use (so views may also
/// bind with `@AppStorage(SettingsStore.Key.…)`), but observable so stores react to changes.
@MainActor
@Observable
public final class SettingsStore {
    public enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: String { rawValue }
        public var title: String { rawValue.capitalized }
    }

    /// UserDefaults keys.
    public enum Key {
        public static let launchAtLogin = "launchAtLogin"
        public static let startEngineOnLaunch = "startEngineOnLaunch"
        public static let showStoppedContainers = "showStoppedContainers"
        public static let hideSystemContainers = "hideSystemContainers"
        public static let menuBarEnabled = "menuBarEnabled"
        public static let pollingInterval = "pollingInterval"
        public static let notifications = "notificationsEnabled"
        public static let appearance = "appearance"
    }

    public static let pollingRange: ClosedRange<Double> = 1...10

    @ObservationIgnored private let defaults: UserDefaults
    /// Hooks for AppModel (polling interval → gate, container filters → store).
    @ObservationIgnored public var onPollingIntervalChange: (@MainActor (Double) -> Void)?
    /// Menu bar / notifications toggled (AppModel starts or stops its background polling client).
    @ObservationIgnored public var onBackgroundNeedsChange: (@MainActor () -> Void)?
    /// Error from the last SMAppService (un)registration, or the "approve in System Settings" note, if any.
    public private(set) var launchAtLoginError: String?
    /// True when macOS registered the login item but the user still has to allow it
    /// (System Settings → General → Login Items).
    public private(set) var launchAtLoginRequiresApproval = false

    /// Mirrors `SMAppService.mainApp.status` (refreshed by `refreshLaunchAtLogin()`); setting it (un)registers.
    public var launchAtLogin: Bool {
        didSet {
            guard !isSyncingLaunchAtLogin else { return }
            applyLaunchAtLogin()
        }
    }
    @ObservationIgnored private var isSyncingLaunchAtLogin = false
    /// Status source; injectable for tests.
    @ObservationIgnored let loginItemStatus: @MainActor () -> SMAppService.Status
    public var startEngineOnLaunch: Bool { didSet { defaults.set(startEngineOnLaunch, forKey: Key.startEngineOnLaunch) } }
    public var showStoppedContainers: Bool { didSet { defaults.set(showStoppedContainers, forKey: Key.showStoppedContainers) } }
    public var hideSystemContainers: Bool { didSet { defaults.set(hideSystemContainers, forKey: Key.hideSystemContainers) } }
    public var menuBarEnabled: Bool {
        didSet { defaults.set(menuBarEnabled, forKey: Key.menuBarEnabled); onBackgroundNeedsChange?() }
    }
    /// Seconds, clamped to 1…10.
    public var pollingInterval: Double {
        didSet {
            let clamped = min(max(pollingInterval, Self.pollingRange.lowerBound), Self.pollingRange.upperBound)
            if clamped != pollingInterval { pollingInterval = clamped; return }
            defaults.set(pollingInterval, forKey: Key.pollingInterval)
            onPollingIntervalChange?(pollingInterval)
        }
    }
    public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Key.notifications); onBackgroundNeedsChange?() }
    }
    public var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }

    public init(defaults: UserDefaults = .standard,
                loginItemStatus: @escaping @MainActor () -> SMAppService.Status = { SMAppService.mainApp.status }) {
        self.defaults = defaults
        self.loginItemStatus = loginItemStatus
        defaults.register(defaults: [
            Key.launchAtLogin: false,
            Key.startEngineOnLaunch: false,
            Key.showStoppedContainers: true,
            Key.hideSystemContainers: true,
            Key.menuBarEnabled: true,
            Key.pollingInterval: 2.0,
            Key.notifications: true,
            Key.appearance: Appearance.system.rawValue,
        ])
        launchAtLogin = false
        startEngineOnLaunch = defaults.bool(forKey: Key.startEngineOnLaunch)
        showStoppedContainers = defaults.bool(forKey: Key.showStoppedContainers)
        hideSystemContainers = defaults.bool(forKey: Key.hideSystemContainers)
        menuBarEnabled = defaults.bool(forKey: Key.menuBarEnabled)
        pollingInterval = min(max(defaults.double(forKey: Key.pollingInterval), 1), 10)
        notificationsEnabled = defaults.bool(forKey: Key.notifications)
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
        refreshLaunchAtLogin()
    }

    /// Re-reads the login item state from the system (the user may change it in System Settings at any time).
    /// Call when the Settings window appears.
    public func refreshLaunchAtLogin() {
        let status = loginItemStatus()
        isSyncingLaunchAtLogin = true
        launchAtLogin = status == .enabled || status == .requiresApproval
        isSyncingLaunchAtLogin = false
        launchAtLoginRequiresApproval = status == .requiresApproval
        if launchAtLoginRequiresApproval {
            launchAtLoginError = "Allow Container Desktop in System Settings → General → Login Items."
        } else if launchAtLoginError?.hasPrefix("Allow ") == true {
            launchAtLoginError = nil
        }
        defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
    }

    private func applyLaunchAtLogin() {
        // SMAppService only works from a bundled, signed app; `swift run` reports an error we surface in Settings.
        var failure: String?
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            failure = error.localizedDescription
        }
        refreshLaunchAtLogin()                       // the system is the source of truth
        if let failure { launchAtLoginError = failure }
    }

    // config.toml load/save lives in `SystemStore` (loadConfigTOML / saveConfigTOML).

    /// Settings summary for diagnostics.
    public var summary: [(String, String)] {
        [("Launch at login", "\(launchAtLogin)"), ("Start engine on launch", "\(startEngineOnLaunch)"),
         ("Show stopped", "\(showStoppedContainers)"), ("Hide system containers", "\(hideSystemContainers)"),
         ("Menu bar", "\(menuBarEnabled)"), ("Polling interval", "\(pollingInterval)s"),
         ("Notifications", "\(notificationsEnabled)"), ("Appearance", appearance.rawValue)]
            + (launchAtLoginRequiresApproval ? [("Login item", "requires approval")] : [])
    }
}
