import Foundation
import Observation
import ContainerKit

/// A pull/push/build/create in flight or recently finished, with its streamed output.
@MainActor
@Observable
public final class LongRunningTask: Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case pull, push, build, run, machine, cluster, load, other

        public var symbol: String {
            switch self {
            case .pull: return "arrow.down.circle"
            case .push: return "arrow.up.circle"
            case .build: return "hammer"
            case .run: return "play.circle"
            case .machine: return "desktopcomputer"
            case .cluster: return "helm"
            case .load: return "square.and.arrow.down.on.square"
            case .other: return "gearshape.2"
            }
        }
    }

    public enum State: Equatable, Sendable {
        case running, succeeded, failed(BackendError), cancelled

        public var isFinished: Bool { self != .running }
        public var label: String {
            switch self {
            case .running: return "Running"
            case .succeeded: return "Done"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            }
        }
    }

    /// Lines kept per task; older lines are dropped so a chatty build cannot exhaust memory.
    public static let maxLines = 5_000

    public let id = UUID()
    public let title: String
    public let kind: Kind
    public let startedAt: Date
    public private(set) var finishedAt: Date?
    public private(set) var lines: [OutputLine] = []
    public private(set) var state: State = .running
    @ObservationIgnored fileprivate var work: Task<Void, Never>?

    init(title: String, kind: Kind, startedAt: Date = .now) {
        self.title = title
        self.kind = kind
        self.startedAt = startedAt
    }

    public var duration: TimeInterval { (finishedAt ?? .now).timeIntervalSince(startedAt) }

    /// Cancels the underlying stream (the backend kills the CLI process).
    public func cancel() { work?.cancel() }

    /// Waits for the task to finish (tests, chained actions).
    public func wait() async { await work?.value }

    fileprivate func append(_ line: OutputLine) {
        lines.append(line)
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    fileprivate func finish(_ state: State) {
        self.state = state
        finishedAt = .now
    }
}

/// Runs `LineStream`s as `LongRunningTask`s and keeps the most recent ones for the Activity panel.
@MainActor
@Observable
public final class TaskCenter {
    public private(set) var tasks: [LongRunningTask] = []
    public var maxRetained = 50
    /// Called when any task finishes (AppModel hooks toasts + system notifications here).
    @ObservationIgnored public var onFinish: (@MainActor (LongRunningTask) -> Void)?

    public init() {}

    public var activeCount: Int { tasks.count { $0.state == .running } }
    public var activeTasks: [LongRunningTask] { tasks.filter { $0.state == .running } }

    /// Consumes `stream` into a new task. `completion` runs after the task finishes (e.g. refresh a store).
    @discardableResult
    public func run(title: String, kind: LongRunningTask.Kind, stream: LineStream,
                    completion: (@MainActor (LongRunningTask.State) async -> Void)? = nil) -> LongRunningTask {
        let task = LongRunningTask(title: title, kind: kind)
        tasks.insert(task, at: 0)
        trim()
        task.work = Task { [weak self, task] in
            var final: LongRunningTask.State = .succeeded
            do {
                for try await line in stream {
                    task.append(line)
                }
                if Task.isCancelled { final = .cancelled }
            } catch {
                let wrapped = BackendError(wrapping: error)
                final = (Task.isCancelled || wrapped == .cancelled) ? .cancelled : .failed(wrapped)
            }
            task.finish(final)
            await completion?(final)
            self?.onFinish?(task)
        }
        return task
    }

    /// Removes finished tasks.
    public func clearFinished() { tasks.removeAll { $0.state.isFinished } }

    private func trim() {
        guard tasks.count > maxRetained else { return }
        // Drop the oldest finished tasks first; never drop a running one.
        while tasks.count > maxRetained, let index = tasks.lastIndex(where: { $0.state.isFinished }) {
            tasks.remove(at: index)
        }
    }
}
