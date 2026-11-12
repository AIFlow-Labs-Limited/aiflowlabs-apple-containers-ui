import Foundation

/// Whether the background helper is set up to run at login.
public enum BackgroundSupervisionStatus: Equatable, Sendable {
    /// Not installed: restart policies are enforced only while the app runs.
    case disabled
    /// Installed and loaded: the helper runs now and at every login.
    case enabled
    /// Installed, but macOS is not running it (switched off under System Settings › General › Login Items, or
    /// it could not be loaded).
    case requiresApproval
    /// It cannot be set up from this copy of the app (the reason, for the user).
    case unavailable(String)

    /// Installed, running or not.
    public var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

/// Installs and removes the background helper. Views never do this themselves; `SettingsStore` does, through
/// this.
public protocol BackgroundSupervisionService: Sendable {
    /// The state as the system reports it now.
    func status() -> BackgroundSupervisionStatus
    /// Installs the helper; it starts right away and at every login.
    func enable() throws
    /// Stops the helper and removes what `enable()` installed.
    func disable() throws
    /// Re-installs the helper when it is installed for another copy or version of the app (moved, updated).
    func repairIfNeeded() throws
}

/// The helper as a per-user LaunchAgent: a property list in `~/Library/LaunchAgents` that runs the app's own
/// executable with `--supervise`, loaded and unloaded with `launchctl`.
///
/// Why not `SMAppService.agent(plistName:)`: with the ad-hoc signature the builds carry, macOS pins the agent to
/// the exact binary that registered it. It ran on the first build, but after the app bundle was replaced by a
/// newer build (what every update does) launchd refused to start it (`OS_REASON_CODESIGNING`) while
/// `SMAppService` still reported it enabled, and registering again did not repair it. A plain LaunchAgent has
/// no such pin. Revisit when builds are signed with a Developer ID.
public struct LaunchAgentSupervisionService: BackgroundSupervisionService {
    /// Runs `/bin/launchctl` with the arguments and returns its exit status and output.
    public typealias Launchctl = @Sendable (_ arguments: [String]) -> (status: Int32, output: String)

    /// The launchd label of the agent, and the name of its property list.
    public static let label = "io.aiflowlabs.containerdesktop.supervisor"
    /// Argument that makes the executable run as the helper instead of opening the app.
    public static let superviseArgument = "--supervise"

    /// `~/Library/LaunchAgents/io.aiflowlabs.containerdesktop.supervisor.plist`.
    public static var standardPlistURL: URL {
        URL.homeDirectory.appending(path: "Library/LaunchAgents/\(label).plist")
    }

    /// The running executable when it is inside an app bundle in a permanent place; `nil` for `swift run`, tests,
    /// and an app macOS runs from a temporary translocated copy.
    public static var bundledExecutable: URL? {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app", let executable = bundle.executableURL,
            !executable.path.contains("/AppTranslocation/")
        else { return nil }
        return executable
    }

    /// Version and build of the running app, as in its Info.plist.
    public static var bundleVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        return "\(version) (\(info["CFBundleVersion"] as? String ?? "0"))"
    }

    private let executable: URL?
    private let plistURL: URL
    private let version: String
    private let bundleIdentifier: String
    private let domain: String
    private let launchctl: Launchctl

    /// - Parameters:
    ///   - executable: what the agent runs; `nil` makes the service unavailable.
    ///   - plistURL: where the agent's property list goes.
    ///   - version: recorded in the property list, so an updated app replaces the helper of the old one.
    ///   - bundleIdentifier: lets System Settings show the helper under the app's name.
    ///   - domain: the launchd domain of the user's session.
    ///   - launchctl: runs `launchctl` (tests pass a fake).
    public init(
        executable: URL? = LaunchAgentSupervisionService.bundledExecutable,
        plistURL: URL = LaunchAgentSupervisionService.standardPlistURL,
        version: String = LaunchAgentSupervisionService.bundleVersion,
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.aiflowlabs.containerdesktop",
        domain: String = "gui/\(getuid())",
        launchctl: @escaping Launchctl = LaunchAgentSupervisionService.runLaunchctl
    ) {
        self.executable = executable
        self.plistURL = plistURL
        self.version = version
        self.bundleIdentifier = bundleIdentifier
        self.domain = domain
        self.launchctl = launchctl
    }

    public func status() -> BackgroundSupervisionStatus {
        guard executable != nil else {
            return .unavailable(
                "Only available when Container Desktop runs from the Applications folder (not from a disk image, "
                    + "and not with `swift run`).")
        }
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return .disabled }
        return isLoaded ? .enabled : .requiresApproval
    }

    public func enable() throws {
        guard let executable else { throw LaunchAgentError("The helper cannot be installed from this copy.") }
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try propertyListData(for: executable).write(to: plistURL, options: .atomic)
        try unload()
        _ = launchctl(["enable", target])  // undoes an earlier `launchctl disable`; harmless otherwise
        let result = launchctl(["bootstrap", domain, plistURL.path])
        guard result.status == 0 || isLoaded else {
            throw LaunchAgentError("launchctl could not load the helper: \(Self.clean(result.output))")
        }
    }

    public func disable() throws {
        try unload()
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return }
        try FileManager.default.removeItem(at: plistURL)
    }

    public func repairIfNeeded() throws {
        guard let executable, FileManager.default.fileExists(atPath: plistURL.path) else { return }
        let installed = (try? Data(contentsOf: plistURL)).flatMap(Self.dictionary)
        let wanted = Self.dictionary(try propertyListData(for: executable))
        if installed != wanted { try enable() }
    }

    // MARK: launchd

    private var target: String { "\(domain)/\(Self.label)" }
    private var isLoaded: Bool { launchctl(["print", target]).status == 0 }

    /// Stops the agent and waits (up to 3 s) until launchd has let go of it, so it can be loaded again.
    private func unload() throws {
        guard isLoaded else { return }
        let result = launchctl(["bootout", target])
        for _ in 0..<30 where isLoaded { Thread.sleep(forTimeInterval: 0.1) }
        guard !isLoaded else {
            throw LaunchAgentError("launchctl could not stop the helper: \(Self.clean(result.output))")
        }
    }

    private func propertyListData(for executable: URL) throws -> Data {
        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": [executable.path, Self.superviseArgument],
            "AssociatedBundleIdentifiers": [bundleIdentifier],
            "RunAtLoad": true,
            // Started again after a crash; a clean exit (SIGTERM when it is switched off) is final.
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 30,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
            "EnvironmentVariables": ["CONTAINER_DESKTOP_HELPER_VERSION": version],
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }

    private static func dictionary(_ data: Data) -> NSDictionary? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? NSDictionary
    }

    private static func clean(_ output: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "no message" : text
    }

    /// Runs `/bin/launchctl` and waits for it (a few milliseconds).
    public static let runLaunchctl: Launchctl = { arguments in
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Why the helper could not be installed or removed.
public struct LaunchAgentError: LocalizedError, Equatable {
    private let message: String

    /// An error the user sees as `message`.
    public init(_ message: String) { self.message = message }

    public var errorDescription: String? { message }
}
