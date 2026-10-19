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
    /// Error from the last SMAppService (un)registration, if any.
    public private(set) var launchAtLoginError: String?

    public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin); applyLaunchAtLogin() }
    }
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

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        startEngineOnLaunch = defaults.bool(forKey: Key.startEngineOnLaunch)
        showStoppedContainers = defaults.bool(forKey: Key.showStoppedContainers)
        hideSystemContainers = defaults.bool(forKey: Key.hideSystemContainers)
        menuBarEnabled = defaults.bool(forKey: Key.menuBarEnabled)
        pollingInterval = min(max(defaults.double(forKey: Key.pollingInterval), 1), 10)
        notificationsEnabled = defaults.bool(forKey: Key.notifications)
        appearance = Appearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
    }

    private func applyLaunchAtLogin() {
        // SMAppService only works from a bundled, signed app; `swift run` reports an error we surface in Settings.
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
    }

    // MARK: config.toml

    /// Reads `~/.config/container/config.toml` through the backend.
    public func loadConfigTOML(using backend: any ContainerBackend) async throws -> String {
        try await backend.readConfigTOML()
    }

    /// Validates and writes config.toml. Throws `BackendError.other` describing the first issue when invalid.
    public func saveConfigTOML(_ text: String, using backend: any ContainerBackend) async throws {
        if let issue = TOMLValidator.validate(text).first {
            throw BackendError.other("config.toml line \(issue.line): \(issue.message)")
        }
        try await backend.writeConfigTOML(text)
    }

    /// Settings summary for diagnostics.
    public var summary: [(String, String)] {
        [("Launch at login", "\(launchAtLogin)"), ("Start engine on launch", "\(startEngineOnLaunch)"),
         ("Show stopped", "\(showStoppedContainers)"), ("Hide system containers", "\(hideSystemContainers)"),
         ("Menu bar", "\(menuBarEnabled)"), ("Polling interval", "\(pollingInterval)s"),
         ("Notifications", "\(notificationsEnabled)"), ("Appearance", appearance.rawValue)]
    }
}
