import ContainerKit
import Foundation
import Observation

/// Executes a `ComposePlan` step by step through the backend, as one Activity task with per-step status.
///
/// It stops at the first failure and leaves everything it created in place; `created` says what that is and
/// `removeCreated(backend:)` undoes it on request.
@MainActor
@Observable
public final class ComposeRun {
    /// Where one step stands.
    public enum StepState: Equatable, Sendable {
        case pending, running, succeeded
        case failed(BackendError)
        /// Not attempted because an earlier step failed or the run was cancelled.
        case skipped
    }

    /// What this run created (not what already existed), in creation order.
    public struct Created: Equatable, Sendable {
        public var networks: [String] = []
        public var volumes: [String] = []
        public var containers: [String] = []

        public var isEmpty: Bool { networks.isEmpty && volumes.isEmpty && containers.isEmpty }

        /// "containers db, web; volume shop_pgdata" — for messages and confirmations.
        public var summary: String {
            func part(_ noun: String, _ names: [String]) -> String? {
                names.isEmpty ? nil : "\(noun)\(names.count == 1 ? "" : "s") \(names.joined(separator: ", "))"
            }
            return [part("container", containers), part("volume", volumes), part("network", networks)]
                .compactMap { $0 }.joined(separator: "; ")
        }
    }

    public let plan: ComposePlan
    /// State per `ComposeStep.id`.
    public private(set) var states: [String: StepState] = [:]
    /// Live detail per `ComposeStep.id` while a wait step runs ("attempt 3", "12 s").
    public private(set) var details: [String: String] = [:]
    public private(set) var created = Created()
    /// The Activity task that carries the output; `nil` until `start`.
    public private(set) var task: LongRunningTask?
    /// The step that failed and why, once the run has failed.
    public private(set) var failure: (step: ComposeStep, error: BackendError)?
    /// Set while `removeCreated` is working.
    public private(set) var isCleaningUp = false

    /// A run of `plan`, not started yet.
    public init(plan: ComposePlan) {
        self.plan = plan
        for step in plan.steps { states[step.id] = .pending }
    }

    public func state(of step: ComposeStep) -> StepState { states[step.id] ?? .pending }

    /// What a running wait step is doing right now, e.g. "Waiting for db to be healthy (attempt 3)".
    public func liveStatus(of step: ComposeStep) -> String? {
        guard state(of: step) == .running, let detail = details[step.id] else { return nil }
        switch step.action {
        case .waitHealthy(let container, _): return "Waiting for \(container) to be healthy (\(detail))"
        case .waitCompleted(let container): return "Waiting for \(container) to finish (\(detail))"
        default: return nil
        }
    }

    public var isRunning: Bool { task?.state == .running }
    public var isFinished: Bool { task?.state.isFinished ?? false }
    public var succeeded: Bool { task?.state == .succeeded }
    public var wasCancelled: Bool { task?.state == .cancelled }
    /// Steps completed so far, for "3 of 7".
    public var completedCount: Int { plan.steps.count { state(of: $0) == .succeeded } }

    /// Starts the run as a `TaskCenter` task (visible in the Activity window). `onFinish` runs once it ends,
    /// with whether every step succeeded.
    @discardableResult
    public func start(
        backend: any ContainerBackend, taskCenter: TaskCenter, onFinish: (@MainActor (Bool) async -> Void)? = nil
    ) -> LongRunningTask {
        if let task { return task }
        let stream = LineStream { continuation in
            let work = Task { @MainActor in
                do {
                    try await self.execute(backend: backend, output: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
        let task = taskCenter.run(title: "Compose up: \(plan.projectName)", kind: .run, stream: stream) { state in
            await onFinish?(state == .succeeded)
        }
        self.task = task
        return task
    }

    private func execute(backend: any ContainerBackend, output: LineStream.Continuation) async throws {
        let total = plan.steps.count
        for (index, step) in plan.steps.enumerated() {
            do {
                try Task.checkCancellation()
                states[step.id] = .running
                output.yield(OutputLine("── [\(index + 1)/\(total)] \(step.title) ──"))
                output.yield(OutputLine("$ \(step.commandLine(maskSecrets: true))"))
                try await perform(step, backend: backend, output: output)
                try Task.checkCancellation()
                states[step.id] = .succeeded
            } catch {
                let wrapped = BackendError(wrapping: error)
                let cancelled = Task.isCancelled || wrapped == .cancelled
                states[step.id] = cancelled ? .skipped : .failed(wrapped)
                for later in plan.steps[(index + 1)...] { states[later.id] = .skipped }
                if !cancelled {
                    failure = (step, wrapped)
                    output.yield(
                        OutputLine("Stopped at step \(index + 1) of \(total): \(step.title) failed.", stream: .stderr))
                    if !created.isEmpty { output.yield(OutputLine("Left in place: \(created.summary).")) }
                }
                throw cancelled ? BackendError.cancelled : wrapped
            }
        }
        output.yield(OutputLine("Project \(plan.projectName) is up: \(plan.containerNames.joined(separator: ", "))."))
    }

    private func perform(
        _ step: ComposeStep, backend: any ContainerBackend, output: LineStream.Continuation
    ) async throws {
        switch step.action {
        case .createNetwork(let name, let subnet, let subnetV6, let labels):
            try await backend.createNetwork(name: name, subnet: subnet, subnetV6: subnetV6, labels: labels)
            created.networks.append(name)
        case .createVolume(let name, let labels):
            try await backend.createVolume(name: name, size: nil, journal: nil, labels: labels)
            created.volumes.append(name)
        case .pullImage(let reference, let platform):
            for try await line in backend.pullImage(reference, platform: platform) { output.yield(line) }
        case .buildImage(let spec):
            for try await line in backend.buildImage(spec) { output.yield(line) }
        case .removeContainer(let name):
            try await backend.deleteContainer(name, force: true)
        case .runContainer(let spec):
            // Recorded before the call: a `run` that fails half-way can still leave a (stopped) container behind.
            if let name = spec.name { created.containers.append(name) }
            for try await line in backend.runContainer(spec) { output.yield(line) }
        case .waitHealthy(let container, let check):
            try await ComposeWait.untilHealthy(container: container, check: check, backend: backend, output: output) {
                self.details[step.id] = "attempt \($0)"
            }
        case .waitCompleted(let container):
            try await ComposeWait.untilCompleted(container: container, backend: backend, output: output) {
                self.details[step.id] = "\($0) s"
            }
        }
    }

    /// Deletes what this run created: its containers (killed if running), then its networks and volumes.
    /// Things that existed before the run, and images, are left alone.
    /// - Returns: one message per resource that could not be removed (empty when everything is gone).
    @discardableResult
    public func removeCreated(backend: any ContainerBackend) async -> [String] {
        isCleaningUp = true
        defer { isCleaningUp = false }
        var failures: [String] = []
        var remaining = Created()
        func attempt(_ name: String, _ kind: String, keep: inout [String], _ body: () async throws -> Void) async {
            do { try await body() } catch {
                let wrapped = BackendError(wrapping: error)
                if case .notFound = wrapped { return }  // never created, or already gone
                keep.append(name)
                failures.append("\(kind) \(name): \(wrapped.errorDescription ?? "failed")")
            }
        }
        let existing = Set(((try? await backend.listContainers(includeStopped: true)) ?? []).map(\.id))
        for name in created.containers.reversed() where existing.contains(name) {
            await attempt(name, "container", keep: &remaining.containers) {
                try await backend.deleteContainer(name, force: true)
            }
        }
        for name in created.networks.reversed() {
            await attempt(name, "network", keep: &remaining.networks) { try await backend.deleteNetwork(name) }
        }
        for name in created.volumes.reversed() {
            await attempt(name, "volume", keep: &remaining.volumes) { try await backend.deleteVolume(name) }
        }
        created = remaining
        return failures
    }
}
