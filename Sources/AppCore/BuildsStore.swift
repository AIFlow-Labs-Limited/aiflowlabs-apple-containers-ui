import Foundation
import Observation
import ContainerKit

/// One entry of the local build history (persisted as JSON).
public struct BuildRecord: Codable, Identifiable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case running, succeeded, failed, cancelled }

    public var id: UUID
    public var tag: String
    public var contextDirectory: String
    public var platforms: [String]
    public var startedAt: Date
    public var finishedAt: Date?
    public var status: Status
    public var log: [String]
    public var errorMessage: String?

    public init(id: UUID = UUID(), tag: String, contextDirectory: String, platforms: [String] = [], startedAt: Date = .now,
                finishedAt: Date? = nil, status: Status = .running, log: [String] = [], errorMessage: String? = nil) {
        self.id = id; self.tag = tag; self.contextDirectory = contextDirectory; self.platforms = platforms
        self.startedAt = startedAt; self.finishedAt = finishedAt; self.status = status; self.log = log
        self.errorMessage = errorMessage
    }

    public var duration: TimeInterval? { finishedAt.map { $0.timeIntervalSince(startedAt) } }

    private enum CodingKeys: String, CodingKey {
        case id, tag, contextDirectory, platforms, startedAt, finishedAt, status, log, errorMessage
    }

    /// Tolerant decoding: fields added after v1 (and an unknown `status`) fall back to defaults instead of
    /// failing the whole history file.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        tag = try c.decode(String.self, forKey: .tag)
        contextDirectory = try c.decodeIfPresent(String.self, forKey: .contextDirectory) ?? ""
        platforms = try c.decodeIfPresent([String].self, forKey: .platforms) ?? []
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date(timeIntervalSince1970: 0)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)).flatMap { $0.flatMap(Status.init(rawValue:)) } ?? .failed
        log = try c.decodeIfPresent([String].self, forKey: .log) ?? []
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

/// On-disk build history (`builds.json`). v1 = `{ "version": 1, "records": [...] }`; a bare array (pre-v1) is
/// still read.
struct BuildHistoryFile: Codable {
    static let currentVersion = 1
    var version: Int
    var records: [BuildRecord]
}

/// BuildKit builder status, builds (streamed through TaskCenter) and persisted history.
@MainActor
@Observable
public final class BuildsStore: PollingStore {
    /// History file: `~/Library/Application Support/Container Desktop/builds.json`.
    public static var defaultHistoryURL: URL {
        URL.applicationSupportDirectory.appending(path: "Container Desktop", directoryHint: .isDirectory)
            .appending(path: "builds.json")
    }
    public static let maxHistory = 100
    public static let maxLogLines = 2_000

    public private(set) var builder: Container?
    public private(set) var history: [BuildRecord] = []
    public var isLoading = false
    public var loadError: BackendError?
    public var actionError: BackendError?
    /// Banner error: `actionError ?? loadError`. Setting `nil` clears both; a value becomes the `actionError`.
    public var lastError: BackendError? {
        get { actionError ?? loadError }
        set { actionError = newValue; if newValue == nil { loadError = nil } }
    }
    public var searchText = ""

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored private let tasks: TaskCenter
    @ObservationIgnored private let historyURL: URL
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.loadError { throw error }
    }
    @ObservationIgnored private let gate: PollingGate

    public init(backend: any ContainerBackend, tasks: TaskCenter, gate: PollingGate, historyURL: URL = BuildsStore.defaultHistoryURL) {
        self.backend = backend
        self.tasks = tasks
        self.gate = gate
        self.historyURL = historyURL
        switch Self.loadHistory(from: historyURL) {
        case .success(let records): history = records
        case .failure(let error): actionError = error
        }
    }

    public var builderRunning: Bool { builder?.isRunning ?? false }

    public var filteredHistory: [BuildRecord] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return history }
        return history.filter { $0.tag.localizedCaseInsensitiveContains(q) || $0.contextDirectory.localizedCaseInsensitiveContains(q) }
    }

    public func refresh() async {
        guard let status = await load({ try await backend.builderStatus() }) else { return }
        builder = status
    }

    // MARK: Builder

    public func startBuilder(cpus: Int? = nil, memory: MemorySize? = nil) async {
        await perform { try await backend.builderStart(cpus: cpus, memory: memory) }
    }

    public func stopBuilder() async { await perform { try await backend.builderStop() } }

    /// Deletes the builder container (resets BuildKit state and cache).
    public func resetBuilder() async { await perform { try await backend.builderDelete() } }

    // MARK: Builds

    /// Starts a build, streams it into the Activity panel and records it in the history.
    @discardableResult
    public func build(_ spec: BuildSpec) -> LongRunningTask {
        let record = BuildRecord(tag: spec.tag, contextDirectory: spec.contextDirectory, platforms: spec.platforms.map(\.slug))
        history.insert(record, at: 0)
        let task = tasks.run(title: "Build \(spec.tag)", kind: .build, stream: backend.buildImage(spec)) { [weak self] _ in
            await self?.refresh()
        }
        Task { [weak self, task] in
            await task.wait()
            self?.complete(record.id, with: task)
        }
        return task
    }

    private func complete(_ id: UUID, with task: LongRunningTask) {
        guard let index = history.firstIndex(where: { $0.id == id }) else { return }
        history[index].finishedAt = task.finishedAt ?? .now
        history[index].log = task.buffer.lines.suffix(Self.maxLogLines).map(\.text)
        switch task.state {
        case .succeeded: history[index].status = .succeeded
        case .running:
            // `wait()` returned without a final state: never report that as a success.
            history[index].status = .failed
            history[index].errorMessage = "The build ended without reporting a result."
        case .cancelled: history[index].status = .cancelled
        case .failed(let error):
            history[index].status = .failed
            history[index].errorMessage = error.errorDescription
        }
        saveHistory()
    }

    public func deleteHistory(_ ids: Set<UUID>) {
        history.removeAll { ids.contains($0.id) }
        saveHistory()
    }

    public func clearHistory() {
        history.removeAll { $0.status != .running }
        saveHistory()
    }

    // MARK: Persistence

    private func saveHistory() {
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
        do {
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = BuildHistoryFile(version: BuildHistoryFile.currentVersion, records: history.filter { $0.status != .running })
            try encoder.encode(file).write(to: historyURL, options: .atomic)
        } catch {
            actionError = .other("Could not save build history: \(error.localizedDescription)")
        }
    }

    /// Reads the history. A missing file is an empty history. An unreadable or newer-version file is moved aside
    /// to `builds.json.bak` (so the next save cannot destroy it) and reported as an error.
    static func loadHistory(from url: URL) -> Result<[BuildRecord], BackendError> {
        guard let data = try? Data(contentsOf: url) else { return .success([]) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let file = try? decoder.decode(BuildHistoryFile.self, from: data), file.version <= BuildHistoryFile.currentVersion {
            return .success(file.records)
        }
        if let legacy = try? decoder.decode([BuildRecord].self, from: data) { return .success(legacy) }
        let backup = url.appendingPathExtension("bak")
        let fm = FileManager.default
        try? fm.removeItem(at: backup)
        do {
            try fm.moveItem(at: url, to: backup)
            return .failure(.other("The build history could not be read and was moved to \(backup.path). A new history was started."))
        } catch {
            return .failure(.other("The build history at \(url.path) could not be read: \(error.localizedDescription)"))
        }
    }
}
