import Foundation
import Testing

@testable import ContainerKit

/// Shared plumbing for the suites that hit the real `container` CLI.
///
/// Everything these suites create is named `cd-it-…` and removed again in a cleanup path that also runs when
/// the test fails. They never touch anything they did not create.
enum Integration {
    /// `true` when `CONTAINER_DESKTOP_INTEGRATION=1`; every real-engine suite is gated on it, so `make check`
    /// never touches the engine.
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_INTEGRATION"] == "1" }

    /// Why a gated suite was skipped.
    static let hint: Comment = "set CONTAINER_DESKTOP_INTEGRATION=1 to run against the real CLI"

    /// BusyBox userland (`stat`, `ls`, `head` are applets).
    static let busyBoxImage = "alpine:latest"
    /// Debian with GNU coreutils.
    static let gnuImage = "python:3.11-slim"

    /// `cd-it-<what>-<8 hex digits>`.
    static func uniqueName(_ what: String) -> String {
        "cd-it-\(what)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// A fresh `cd-it-…` folder under the temporary directory. The name contains a space on purpose.
    static func makeTemporaryFolder(_ what: String = "tmp") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: uniqueName(what) + " dir")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Starts a detached throwaway container from a local image, runs `body` with its name, and always
    /// force-deletes it afterwards.
    static func withContainer<T: Sendable>(
        _ backend: CLIBackend, image: String = busyBoxImage, command: [String] = ["sleep", "600"],
        configure: (inout RunSpec) -> Void = { _ in }, _ body: (String) async throws -> T
    ) async throws -> T {
        let name = uniqueName("ctr")
        var spec = RunSpec(image: image)
        spec.name = name
        spec.command = command
        configure(&spec)
        do {
            for try await _ in backend.runContainer(spec) {}
            let result = try await body(name)
            try? await backend.deleteContainer(name, force: true)
            return result
        } catch {
            try? await backend.deleteContainer(name, force: true)
            throw error
        }
    }

    /// Runs a shell script inside the container and requires it to succeed.
    @discardableResult
    static func shell(_ backend: CLIBackend, _ id: String, _ script: String) async throws -> String {
        let result = try await backend.execCapture(id, command: ["sh", "-c", script], workingDirectory: nil)
        try #require(result.exitCode == 0, "`\(script)` failed: \(result.stderr)")
        return result.stdout
    }

    /// The thrown `BackendError`, or `nil` when `body` did not throw one.
    static func backendError(_ body: () async throws -> Void) async -> BackendError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? BackendError
        }
    }
}
