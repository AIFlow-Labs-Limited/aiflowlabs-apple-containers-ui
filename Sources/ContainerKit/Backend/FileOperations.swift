import Foundation

/// Browsing and changing a container's filesystem (the Files tab), plus `container commit`.
///
/// Paths inside the container are absolute POSIX paths. Listing, reading and the mutating calls need a
/// *running* container (they use `container exec` / `container cp`); `commitContainer` also works on a stopped
/// one. Every failure is a `BackendError` that carries the exact command.
public protocol ContainerFileOperations: Sendable {
    /// Lists one directory with a single non-interactive exec. At most `limit` entries are returned
    /// (`isTruncated` says when there are more). An image with no shell or no listing tool yields a listing
    /// whose `unavailable` is set instead of an error.
    func listDirectory(_ id: String, path: String, limit: Int) async throws -> ContainerDirectoryListing
    /// The first `maxBytes` bytes of a file (for previews). Never reads more than `maxBytes`.
    func readFile(_ id: String, path: String, maxBytes: Int) async throws -> Data
    /// `mkdir` inside the container. Fails when the path already exists.
    func makeDirectory(_ id: String, path: String) async throws
    /// `mv` inside the container (rename or move).
    func moveItem(_ id: String, from source: String, to destination: String) async throws
    /// `rm -rf` inside the container. Implementations refuse `/` and system directories
    /// (`ContainerPath.deletionRefusal`) before running anything.
    func deleteItem(_ id: String, path: String) async throws
    /// Copies a file or folder out of the container to exactly `localPath` on the Mac, replacing what is there.
    func copyOut(_ id: String, path: String, to localPath: String) async throws
    /// Copies a file or folder from the Mac to exactly `path` inside the container.
    func copyIn(_ id: String, localPath: String, to path: String) async throws
    /// Whether this runtime has `container commit` (Apple container 1.6 or later). Cached after the first
    /// definite answer; `false` when it cannot be determined.
    func supportsCommit() async -> Bool
    /// `container commit`: saves the container's filesystem as a new image named `reference`.
    func commitContainer(_ id: String, reference: String) -> LineStream
}
