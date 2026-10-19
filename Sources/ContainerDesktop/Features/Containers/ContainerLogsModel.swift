import Foundation
import Observation
import ContainerKit
import AppCore

/// Owns the `container logs` stream for the Logs tab: a managed task (cancelled on stop / re-start),
/// lines batched into a 20k-line ring buffer every 100 ms so a chatty container does not re-render per line.
@MainActor
@Observable
final class ContainerLogsModel {
    private(set) var buffer = LogRingBuffer(capacity: 20_000)
    private(set) var isStreaming = false
    private(set) var error: BackendError?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var pending: [OutputLine] = []

    /// Starts (or restarts) streaming. Running containers follow; stopped ones return what was recorded.
    func start(backend: any ContainerBackend, id: String, follow: Bool, boot: Bool, tail: Int = 1000) {
        stop()
        buffer.removeAll()
        pending.removeAll()
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
        buffer.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
    }
}
