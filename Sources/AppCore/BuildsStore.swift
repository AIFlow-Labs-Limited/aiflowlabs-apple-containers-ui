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
        history = Self.loadHistory(from: historyURL)
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
        case .running, .succeeded: history[index].status = .succeeded
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
            try encoder.encode(history.filter { $0.status != .running }).write(to: historyURL, options: .atomic)
        } catch {
            lastError = .other("Could not save build history: \(error.localizedDescription)")
        }
    }

    private static func loadHistory(from url: URL) -> [BuildRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([BuildRecord].self, from: data)) ?? []
    }
}
