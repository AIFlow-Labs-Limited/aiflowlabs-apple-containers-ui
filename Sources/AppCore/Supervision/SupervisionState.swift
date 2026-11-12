import Foundation

/// What the user asked for that a restart supervisor must respect, shared between the app and the background
/// helper: whoever enforces restart policies reads it before every look at the containers.
public struct SupervisionState: Codable, Equatable, Sendable {
    /// Containers stopped, killed or deleted from the app (id → time of the request). They stay down.
    public var stops: [String: Date]
    /// When the app last asked the container system to stop. Its containers going down is not a crash.
    public var engineStopRequested: Date?

    /// Nothing recorded.
    public init(stops: [String: Date] = [:], engineStopRequested: Date? = nil) {
        self.stops = stops
        self.engineStopRequested = engineStopRequested
    }
}

/// Where `SupervisionState` is kept. `update` is one read-modify-write that no other writer can interleave with,
/// so the app recording a stop and the helper clearing a spent mark never lose each other's change.
public protocol SupervisionStateStore {
    /// The state as it is stored now.
    func read() -> SupervisionState
    /// Applies `change` to the stored state and returns the result.
    @discardableResult func update(_ change: (inout SupervisionState) -> Void) -> SupervisionState
}

/// `SupervisionState` in `UserDefaults`: enough when only one process enforces (tests, mock runs, `swift run`).
public struct DefaultsSupervisionState: SupervisionStateStore {
    private let defaults: UserDefaults
    /// UserDefaults key of the stops (id → seconds since 1970).
    public static let stopsKey = "restartPolicy.intentionalStops"
    /// UserDefaults key of the engine stop request (seconds since 1970).
    public static let engineStopKey = "restartPolicy.engineStopRequested"

    /// Keeps the state in `defaults`.
    public init(_ defaults: UserDefaults) { self.defaults = defaults }

    public func read() -> SupervisionState {
        let stops = defaults.dictionary(forKey: Self.stopsKey) as? [String: Double] ?? [:]
        let engineStop = defaults.object(forKey: Self.engineStopKey) as? Double
        return SupervisionState(
            stops: stops.mapValues { Date(timeIntervalSince1970: $0) },
            engineStopRequested: engineStop.map { Date(timeIntervalSince1970: $0) })
    }

    @discardableResult
    public func update(_ change: (inout SupervisionState) -> Void) -> SupervisionState {
        let before = read()
        var state = before
        change(&state)
        guard state != before else { return state }
        defaults.set(state.stops.mapValues(\.timeIntervalSince1970), forKey: Self.stopsKey)
        if let engineStop = state.engineStopRequested {
            defaults.set(engineStop.timeIntervalSince1970, forKey: Self.engineStopKey)
        } else {
            defaults.removeObject(forKey: Self.engineStopKey)
        }
        return state
    }
}

/// `SupervisionState` as a small JSON file both the app and the background helper open
/// (`~/Library/Application Support/Container Desktop/Supervision/state.json`).
///
/// Writes replace the file atomically, so a reader never sees half of one. `update` holds an advisory lock on a
/// sidecar file for the read-modify-write, which keeps two processes from overwriting each other. The file holds
/// container names and timestamps only.
public struct FileSupervisionState: SupervisionStateStore, Sendable {
    /// The JSON file.
    public let url: URL

    /// Keeps the state in the file at `url` (created with its folder on the first write).
    public init(url: URL) { self.url = url }

    public func read() -> SupervisionState {
        guard let data = try? Data(contentsOf: url) else { return SupervisionState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // An unreadable file is treated as empty and replaced by the next write.
        return (try? decoder.decode(SupervisionState.self, from: data)) ?? SupervisionState()
    }

    @discardableResult
    public func update(_ change: (inout SupervisionState) -> Void) -> SupervisionState {
        let lock = FileLock(url: url.appendingPathExtension("lock"))
        // Without the lock (unwritable folder) the write is still attempted: a rare lost update is better than
        // dropping the user's stop.
        _ = lock.lock()
        defer { lock.unlock() }
        let before = read()
        var state = before
        change(&state)
        guard state != before else { return state }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return before }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) } catch { return before }
        return state
    }

    /// Copies stops recorded by an earlier version (in `defaults`) into the file, once: only while the file does
    /// not exist yet.
    public func adoptStops(from defaults: UserDefaults) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let earlier = DefaultsSupervisionState(defaults).read()
        guard !earlier.stops.isEmpty else { return }
        update { $0.stops = earlier.stops }
    }
}
