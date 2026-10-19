import Foundation
import Observation
import ContainerKit

/// Outcome of a per-id bulk action: every id is attempted, failures are collected instead of aborting.
// TODO(merge): use `BulkResult` from `Store.performEach(ids:_:)` once AppCore's Store.swift lands it.
public struct ContainersBulkResult: Sendable, Equatable {
    public var succeeded: [String] = []
    public var failures: [Failure] = []

    public struct Failure: Sendable, Equatable {
        public var id: String
        public var error: BackendError
    }

    public init() {}

    public var attempted: Int { succeeded.count + failures.count }
    public var isSuccess: Bool { failures.isEmpty }

    /// "Deleted 8 of 10 containers; failed: a (message), b (message)" — or "Deleted web" / "Deleted 3 containers".
    public func summary(verb: String) -> String {
        if failures.isEmpty {
            return succeeded.count == 1 ? "\(verb) \(succeeded[0])" : "\(verb) \(succeeded.count) containers"
        }
        let failed = failures.map { "\($0.id) (\($0.error.errorDescription ?? "failed"))" }.joined(separator: ", ")
        return "\(verb) \(succeeded.count) of \(attempted) containers; failed: \(failed)"
    }

    /// One error summarising every failure (for `lastError` / banners), `nil` when everything succeeded.
    public var combinedError: BackendError? {
        guard let first = failures.first else { return nil }
        if failures.count == 1 { return first.error }
        return .other(failures.map { "\($0.id): \($0.error.errorDescription ?? "failed")" }.joined(separator: "\n"))
    }
}

/// Containers list, filters, live stats and lifecycle actions.
@MainActor
@Observable
public final class ContainersStore: PollingStore {
    /// How long a user-initiated stop stays "expected" if the container is never seen stopped.
    public static let expectedStopTTL: TimeInterval = 60

    public private(set) var items: [Container] = []
    public var isLoading = false
    public var lastError: BackendError?
    public var showStopped = true
    public var hideSystemManaged = true
    public var searchText = ""
    /// Latest stats sample per container id.
    public private(set) var stats: [String: ContainerStats] = [:]
    /// CPU % per container (100 = one core), from the last two samples.
    public private(set) var cpuPercent: [String: Double] = [:]
    /// Rolling 5-minute history per container, fed by every `refreshStats` (the Stats tab only renders it).
    public let statsHistory = ContainerStatsHistory(window: 300)
    /// Called when a container stops without the app having asked it to (crash notification).
    @ObservationIgnored public var onUnexpectedExit: (@MainActor (Container) -> Void)?
    /// Clock for expected-stop expiry (tests override it).
    @ObservationIgnored var now: () -> Date = { Date() }

    @ObservationIgnored private let backend: any ContainerBackend
    @ObservationIgnored public private(set) lazy var poller = Poller(gate: gate) { [weak self] in
        guard let self else { return }
        await self.refresh()
        if let error = self.lastError { throw error }
        await self.refreshStats()
    }
    @ObservationIgnored private let gate: PollingGate
    @ObservationIgnored private var lastSampleAt: Date?
    /// Ids the app is stopping/killing/restarting/deleting → when that was requested. An entry is dropped when the
    /// container is seen stopped (or gone), or after `expectedStopTTL` — never wholesale on a refresh, so a poll
    /// that lands while a slow stop is still in flight cannot turn it into an "exited unexpectedly" alert.
    @ObservationIgnored private var expectedStops: [String: Date] = [:]
    @ObservationIgnored private var hasLoadedOnce = false

    public init(backend: any ContainerBackend, gate: PollingGate) {
        self.backend = backend
        self.gate = gate
    }

    // MARK: Derived

    /// Items after the stopped/system/search filters.
    public var filtered: [Container] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        return items.filter { c in
            (showStopped || c.isRunning)
                && (!hideSystemManaged || !c.isSystemManaged)
                && (q.isEmpty || c.id.localizedCaseInsensitiveContains(q) || c.imageReference.localizedCaseInsensitiveContains(q)
                    || (c.labels[AppLabel.project]?.localizedCaseInsensitiveContains(q) ?? false))
        }
    }

    public var runningCount: Int { items.count { $0.isRunning && !$0.isSystemManaged } }
    public var visibleCount: Int { items.count { !hideSystemManaged || !$0.isSystemManaged } }
    public var running: [Container] { items.filter { $0.isRunning && !$0.isSystemManaged } }
    /// Stopped containers the user owns (what "Prune" / "Clean up" remove; builder and k8s nodes excluded).
    public var prunable: [Container] { items.filter { !$0.isRunning && !$0.isSystemManaged } }
    public var totalCPUPercent: Double { cpuPercent.values.reduce(0, +) }
    public var totalMemoryBytes: Int64 { stats.values.reduce(0) { $0 + $1.memoryUsageBytes } }

    public func container(id: String) -> Container? { items.first { $0.id == id } }

    /// Whether `id` is currently in the expected-stop set (for tests/diagnostics).
    public func isExpectingStop(_ id: String) -> Bool { expectedStops[id] != nil }

    // MARK: Loading

    public func refresh() async {
        guard let list = await load({ try await backend.listContainers(includeStopped: true) }) else { return }
        detectUnexpectedExits(new: list)
        items = list.sorted { $0.configuration.creationDate > $1.configuration.creationDate }
        hasLoadedOnce = true
    }

    /// Samples stats for running containers, updates `cpuPercent` from the previous sample and appends to `statsHistory`.
    public func refreshStats(now date: Date = .now) async {
        let ids = items.filter(\.isRunning).map(\.id)
        guard !ids.isEmpty else { stats = [:]; cpuPercent = [:]; return }
        guard let samples = try? await backend.containerStats(ids: ids) else { return }
        var percent: [String: Double] = [:]
        if let last = lastSampleAt {
            let interval = date.timeIntervalSince(last)
            for sample in samples {
                if let previous = stats[sample.id] {
                    percent[sample.id] = ContainerStats.cpuPercent(previous: previous, current: sample, interval: interval)
                }
            }
        }
        for sample in samples { statsHistory.append(sample, at: date) }
        stats = Dictionary(samples.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        cpuPercent = percent
        lastSampleAt = date
    }

    private func detectUnexpectedExits(new list: [Container]) {
        let current = now()
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        // Report first (an id seen stopped in this very refresh is still expected), then expire.
        if hasLoadedOnce, let onUnexpectedExit {
            let wasRunning = Set(items.filter(\.isRunning).map(\.id))
            for c in list where wasRunning.contains(c.id) && !c.isRunning && !isExpected(c.id, at: current) {
                onUnexpectedExit(c)
            }
        }
        for (id, since) in expectedStops {
            let seenStopped = byID[id].map { !$0.isRunning } ?? true
            if seenStopped || current.timeIntervalSince(since) > Self.expectedStopTTL { expectedStops[id] = nil }
        }
    }

    private func isExpected(_ id: String, at date: Date) -> Bool {
        guard let since = expectedStops[id] else { return false }
        return date.timeIntervalSince(since) <= Self.expectedStopTTL
    }

    private func expectStops(_ ids: [String]) {
        let date = now()
        for id in ids { expectedStops[id] = date }
    }

    // MARK: Actions

    /// Runs `body` for every id (a failure never skips the rest), refreshes once, and records a combined
    /// `lastError` when anything failed.
    // TODO(merge): use `performEach(ids:_:)` from AppCore's Store.swift.
    @discardableResult
    private func performEachID(_ ids: [String], _ body: (String) async throws -> Void) async -> ContainersBulkResult {
        var result = ContainersBulkResult()
        for id in ids {
            do {
                try await body(id)
                result.succeeded.append(id)
            } catch {
                result.failures.append(.init(id: id, error: BackendError(wrapping: error)))
            }
        }
        await refresh()
        if let error = result.combinedError { lastError = error }
        return result
    }

    @discardableResult
    public func start(_ ids: [String]) async -> ContainersBulkResult {
        await performEachID(ids) { try await backend.startContainer($0) }
    }

    @discardableResult
    public func stop(_ ids: [String], timeoutSeconds: Int? = nil) async -> ContainersBulkResult {
        expectStops(ids)
        return await performEachID(ids) { try await backend.stopContainer($0, timeoutSeconds: timeoutSeconds, signal: nil) }
    }

    @discardableResult
    public func kill(_ ids: [String], signal: String? = nil) async -> ContainersBulkResult {
        expectStops(ids)
        return await performEachID(ids) { try await backend.killContainer($0, signal: signal) }
    }

    /// Stop + start per id; a failure on one container does not skip the others.
    @discardableResult
    public func restart(_ ids: [String]) async -> ContainersBulkResult {
        expectStops(ids)
        let running = Set(items.filter(\.isRunning).map(\.id))
        return await performEachID(ids) { id in
            if running.contains(id) || container(id: id) == nil {
                try await backend.stopContainer(id, timeoutSeconds: nil, signal: nil)
            }
            statsHistory.reset(id)   // counters restart with the process
            try await backend.startContainer(id)
        }
    }

    /// Deletes each id. `force` only applies to containers that are running (a stopped container is always
    /// removed without `--force`), so "force" means "kill running ones and remove them".
    @discardableResult
    public func delete(_ ids: [String], force: Bool = false) async -> ContainersBulkResult {
        let running = Set(items.filter(\.isRunning).map(\.id))
        expectStops(ids.filter(running.contains))
        let result = await performEachID(ids) { id in
            try await backend.deleteContainer(id, force: force && running.contains(id))
        }
        for id in result.succeeded { statsHistory.reset(id) }
        return result
    }

    /// Removes stopped containers the user owns — explicitly by id, never `container prune`, so builder and
    /// Kubernetes node containers (`isSystemManaged`) are left alone.
    @discardableResult
    public func prune() async -> ContainersBulkResult {
        await delete(prunable.map(\.id), force: false)
    }
}

// MARK: - Secrets in container settings

/// Masking of environment values whose key looks secret, for previews, copies, persistence and Inspect.
// TODO(merge): use `EnvironmentVariable.isSensitive` as the single masker everywhere and
// `RunSpec.commandLineString(maskSecrets:)` for the run command once AppCore lands them.
public enum ContainerSecrets {
    public static let mask = "••••••"

    public static func isSensitive(key: String) -> Bool { EnvironmentVariable(key: key, value: nil).isSensitive }

    /// `KEY=VALUE` entries with sensitive values replaced by `mask` (bare `KEY` and empty values unchanged).
    public static func masked(_ entries: [String]) -> [String] {
        entries.map { entry in
            let v = EnvironmentVariable(parsing: entry)
            guard v.isSensitive, let value = v.value, !value.isEmpty else { return entry }
            return "\(v.key)=\(mask)"
        }
    }

    /// Whether any entry carries a non-empty sensitive value.
    public static func containsSecrets(_ entries: [String]) -> Bool { masked(entries) != entries }

    /// `container run …` for `spec`, optionally with sensitive `-e` values masked.
    public static func runCommandLine(_ spec: RunSpec, maskSecrets: Bool) -> String {
        guard maskSecrets else { return spec.commandLineString }
        var masked = spec
        masked.environment = Self.masked(spec.environment)
        return masked.commandLineString
    }
}

// MARK: - Shell commands for terminals

/// Validation and quoting for the Terminal tab's shell picker and the Terminal.app hand-off.
public enum ContainerShell {
    /// Shell names accepted without a path (resolved inside the container's PATH).
    public static let knownShells: Set<String> = ["sh", "ash", "bash", "dash", "zsh", "fish", "ksh", "mksh", "tcsh", "csh", "busybox"]

    /// `nil` when `text` is a usable custom shell: one word, no shell metacharacters, either an absolute path
    /// or a known shell name. Otherwise a user-facing reason.
    public static func validationError(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Enter a shell, e.g. /bin/ash." }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"$`\\|&;<>()*?[]{}!#~=%^,"))
        if t.rangeOfCharacter(from: forbidden) != nil { return "Use a single shell path without spaces or special characters." }
        if t.hasPrefix("/") { return t.contains("/../") || t.hasSuffix("/") ? "“\(t)” is not a valid shell path." : nil }
        return knownShells.contains(t) ? nil : "Use an absolute path (e.g. /bin/ash) or one of: \(knownShells.sorted().joined(separator: ", "))."
    }

    /// POSIX single-quoting of every word, so `sh -c` / zsh run it literally (`|`, `>`, `*`, `~`, `'`… included).
    // TODO(merge): use ContainerKit `ShellQuote` (and the fixed `CommandLine.display`).
    public static func quoted(_ words: [String]) -> String {
        words.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
    }
}
