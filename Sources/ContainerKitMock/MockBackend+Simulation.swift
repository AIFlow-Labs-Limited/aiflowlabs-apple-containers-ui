import ContainerKit
import Foundation

// Hooks that let tests and previews play what a real engine does on its own: a container that exits, a start
// that fails, a health check that passes on the third try.
extension MockBackend {
    /// Result of a scripted `execCapture`: called with the container id and the command.
    public typealias ExecHandler =
        @Sendable (_ id: String, _ command: [String]) async -> (exitCode: Int32, stdout: String, stderr: String)

    /// Scripts every later `execCapture` (`nil` restores the canned success).
    public func setExecHandler(_ handler: ExecHandler?) { execHandler = handler }

    /// The container's own process ends, as after a crash: it is stopped and keeps the date of its last start.
    /// Nothing is told to the caller, exactly like the real runtime (which also reports no exit code).
    public func simulateExit(_ id: String) throws {
        try update(id) { $0.status = Container.Status(state: .stopped, startedDate: $0.status?.startedDate) }
    }

    /// Replaces the clock that stamps container starts.
    public func setClock(_ clock: @escaping @Sendable () -> Date) { currentDate = clock }

    /// Makes `startContainer(id)` fail (or work again) until told otherwise.
    public func setStartFails(_ fails: Bool, for id: String) {
        if fails { failingStarts.insert(id) } else { failingStarts.remove(id) }
    }

    /// Adds a container with the given labels and state, for tests that need more than the fixtures.
    /// A container of the same id (the sample data has a `db` and a `cache`) is replaced.
    public func addContainer(
        id: String, image: String = "docker.io/library/alpine:latest", labels: [String: String] = [:],
        running: Bool = true, startedDate: Date? = nil, creationDate: Date? = nil
    ) {
        let startedDate = startedDate ?? currentDate()
        let creationDate = creationDate ?? currentDate()
        let descriptor = Descriptor(
            digest: "sha256:" + MockBackend.fakeDigest(image), mediaType: "application/vnd.oci.image.index.v1+json",
            size: 1000)
        let configuration = Container.Configuration(
            id: id, image: ImageReference(reference: image, descriptor: descriptor), creationDate: creationDate,
            initProcess: .init(executable: "sh"), labels: labels)
        let status = Container.Status(state: running ? .running : .stopped, startedDate: startedDate)
        containers.removeAll { $0.id == id }
        containers.append(Container(id: id, configuration: configuration, status: status))
    }
}
