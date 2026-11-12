import ContainerKit
import Foundation

/// One unit of a multi-step Activity task (e.g. one file of an upload).
public struct TaskStep: Sendable {
    /// Line printed before the step runs (what is about to happen).
    public var label: String
    /// The work; throwing fails the whole task.
    public var work: @Sendable () async throws -> Void

    /// Creates a step.
    public init(_ label: String, work: @escaping @Sendable () async throws -> Void) {
        self.label = label
        self.work = work
    }
}

extension TaskCenter {
    /// Runs one-shot backend calls (which print nothing themselves) as an Activity task: each step's label is
    /// streamed before it runs and `summary` when all succeeded, so the user sees progress and can cancel.
    @discardableResult
    public func run(
        title: String, kind: LongRunningTask.Kind = .other, steps: [TaskStep], summary: String,
        completion: (@MainActor (LongRunningTask.State) async -> Void)? = nil
    ) -> LongRunningTask {
        let stream = LineStream { continuation in
            let task = Task {
                do {
                    for step in steps {
                        try Task.checkCancellation()
                        continuation.yield(OutputLine(step.label))
                        try await step.work()
                    }
                    continuation.yield(OutputLine(summary))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return run(title: title, kind: kind, stream: stream, completion: completion)
    }
}
