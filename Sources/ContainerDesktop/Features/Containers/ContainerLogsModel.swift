import AppCore
import ContainerKit
import Foundation
import Observation

/// Owns the `container logs` stream for the Logs tab: a managed task (cancelled on stop / re-start),
/// lines batched into a 20k-line ring buffer every 100 ms so a chatty container does not re-render per line.
///
/// Search is indexed here, not in the view: `matches` holds *absolute* line numbers (`droppedCount + offset`, stable
/// when the ring trims), is extended incrementally on every flush and fully recomputed only when the query changes
/// (debounced 150 ms).
@MainActor
@Observable
final class ContainerLogsModel {
    private(set) var buffer = LogRingBuffer(capacity: 20_000)
    private(set) var isStreaming = false
    private(set) var error: BackendError?
    /// The applied (debounced, trimmed) search query.
    private(set) var query = ""
    /// Absolute line numbers of matching lines, ascending.
    private(set) var matches: [Int] = []
    private(set) var matchSet = Set<Int>()

    @ObservationIgnored private var queryTask: Task<Void, Never>?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [OutputLine] = []

    /// Starts (or restarts) streaming. Running containers follow; stopped ones return what was recorded.
    func start(backend: any ContainerBackend, id: String, follow: Bool, boot: Bool, tail: Int = 1000) {
        stop()
        buffer.removeAll()
        pending.removeAll()
        resetMatches()
        error = nil
        isStreaming = true
        let stream = backend.containerLogs(id, follow: follow, boot: boot, tail: boot ? nil : tail)
        task = Task { [weak self] in
            do {
                for try await line in stream {
                    guard let self else { return }
                    self.enqueue(line)
                }
            } catch {
                let wrapped = BackendError(wrapping: error)
                if wrapped != .cancelled, !Task.isCancelled { self?.error = wrapped }
            }
            guard let self else { return }
            self.flush()
            if !Task.isCancelled { self.isStreaming = false }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        flushTask?.cancel()
        flushTask = nil
        isStreaming = false
    }

    /// Empties the view; the stream keeps running and the container's own log is untouched.
    func clear() {
        pending.removeAll()
        buffer.removeAll()
        resetMatches()
    }

    /// Sets the search query after `debounce`; typing fast recomputes once.
    func setQuery(_ text: String, debounce: Duration = .milliseconds(150)) {
        queryTask?.cancel()
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q != query else { return }
        queryTask = Task { [weak self] in
            if debounce > .zero { try? await Task.sleep(for: debounce) }
            guard !Task.isCancelled, let self else { return }
            self.query = q
            self.recomputeMatches()
        }
    }

    /// Line at absolute number `n` (`buffer.droppedCount ..< buffer.totalAppended`).
    func line(_ n: Int) -> OutputLine {
        let lines = buffer.lines
        return lines[lines.startIndex + (n - buffer.droppedCount)]
    }

    private func resetMatches() {
        matches = []
        matchSet = []
    }

    private func recomputeMatches() {
        let base = buffer.droppedCount
        matches = buffer.matches(query).map { base + $0 }
        matchSet = Set(matches)
    }

    private func enqueue(_ line: OutputLine) {
        pending.append(line)
        if pending.count >= 2_000 { flush(); return }
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let firstNew = buffer.totalAppended
        buffer.append(contentsOf: pending)
        if !query.isEmpty {
            let added = pending.indices.filter { pending[$0].text.localizedCaseInsensitiveContains(query) }.map {
                firstNew + $0
            }
            matches.append(contentsOf: added)
            matchSet.formUnion(added)
        }
        // Forget matches the ring trimmed away.
        let dropped = buffer.droppedCount
        if let first = matches.first, first < dropped {
            let cut = matches.firstIndex { $0 >= dropped } ?? matches.count
            matchSet.subtract(matches[..<cut])
            matches.removeFirst(cut)
        }
        pending.removeAll(keepingCapacity: true)
    }
}
