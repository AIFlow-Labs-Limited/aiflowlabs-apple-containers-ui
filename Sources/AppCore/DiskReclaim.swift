import ContainerKit
import Foundation

/// "Reclaim Disk Space": `container clean` (Apple container 1.7+) as an Activity task.
///
/// The command gives blocks that were freed inside running containers (deleted files on the root filesystem and
/// on named volumes) back to the Mac. It deletes nothing, so it runs without a confirmation. The task's output
/// starts with the exact command, then what the CLI prints, then one line saying what happened.
public enum DiskReclaim {
    /// Of `containers`, the ids `container clean` accepts: the running ones.
    public static func eligible(_ containers: [Container]) -> [String] {
        containers.filter(\.isRunning).map(\.id)
    }

    /// Activity title: `Reclaim disk space of web`, or `… of 3 containers`.
    public static func title(for ids: [String]) -> String {
        ids.count == 1 ? "Reclaim disk space of \(ids[0])" : "Reclaim disk space of \(ids.count) containers"
    }

    /// The closing line of a successful run.
    public static func summary(for ids: [String]) -> String {
        let what = ids.count == 1 ? ids[0] : "\(ids.count) containers"
        return "Unused space in \(what) was given back to the Mac. Nothing inside was deleted."
    }

    /// The command line first, then the backend's output, then `summary`.
    public static func stream(ids: [String], backend: any ContainerBackend) -> LineStream {
        LineStream { continuation in
            let work = Task {
                do {
                    continuation.yield(OutputLine("$ " + CLIBackend.cleanCommandPreview(ids)))
                    for try await line in backend.cleanContainers(ids) { continuation.yield(line) }
                    continuation.yield(OutputLine(summary(for: ids)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    /// Starts the task for the running containers among `containers`; `nil` when none of them is running.
    /// `completion` runs when it ends (the caller refreshes its disk usage figure there).
    @MainActor
    @discardableResult
    public static func run(
        _ containers: [Container], backend: any ContainerBackend, taskCenter: TaskCenter,
        completion: (@MainActor (LongRunningTask.State) async -> Void)? = nil
    ) -> LongRunningTask? {
        let ids = eligible(containers)
        guard !ids.isEmpty else { return nil }
        return taskCenter.run(
            title: title(for: ids), kind: .other, stream: stream(ids: ids, backend: backend), completion: completion)
    }
}
