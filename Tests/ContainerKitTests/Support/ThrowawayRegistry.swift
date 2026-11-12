import Foundation
import Testing

@testable import ContainerKit

/// A `registry:2` container for the registry integration suite: started for one test, reached at its own
/// address (`<container ip>:5000`, plain HTTP), and force-deleted afterwards. Named `cd-it-reg-…`.
///
/// No real registry and no real credentials are involved. When authentication is asked for, the password is a
/// random string made up by the test, hashed by `/usr/sbin/htpasswd` (which reads it from stdin) into a
/// temporary folder that is mounted into the container.
enum ThrowawayRegistry {
    static let image = "docker.io/library/registry:2"
    static let user = "cdit"

    /// Makes sure the registry image is local. `nil` when it is not and cannot be pulled (offline, rate limit):
    /// the caller then returns without testing anything. Otherwise whether this call pulled it, so that the
    /// caller can remove it again and leave the image store as it found it.
    static func ensureImage(_ backend: CLIBackend) async -> Bool? {
        if (try? await backend.inspectImage(image)) != nil { return false }
        do {
            for try await _ in backend.pullImage(image, platform: .arm64) {}
            return true
        } catch {
            return nil
        }
    }

    /// Starts a registry, runs `body` with its `host:port`, and always deletes the container. With
    /// `htpasswdFolder` the registry asks for the basic-auth login stored in that folder's `htpasswd` file.
    static func with<T: Sendable>(
        _ backend: CLIBackend, htpasswdFolder: URL? = nil,
        _ body: (_ host: String, _ container: String) async throws -> T
    ) async throws -> T {
        let name = Integration.uniqueName("reg")
        var spec = RunSpec(image: image)
        spec.name = name
        if let htpasswdFolder {
            spec.mounts = [.init(kind: .bind(hostPath: htpasswdFolder.path), target: "/auth", readOnly: true)]
            spec.environment = [
                "REGISTRY_AUTH=htpasswd", "REGISTRY_AUTH_HTPASSWD_REALM=cd-it",
                "REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd",
            ]
        }
        do {
            for try await _ in backend.runContainer(spec) {}
            let address = try #require(try await backend.inspectContainer(name).primaryIPv4)
            try await waitUntilServing(backend, name)
            let result = try await body("\(address):5000", name)
            try? await backend.deleteContainer(name, force: true)
            return result
        } catch {
            try? await backend.deleteContainer(name, force: true)
            throw error
        }
    }

    /// What the registry answers on `/v2/…` from inside its own container (`{}`, a catalog, or a 401 line).
    static func get(_ backend: CLIBackend, _ container: String, _ path: String) async throws -> String {
        let result = try await backend.execCapture(
            container, command: ["sh", "-c", "wget -q -O- http://127.0.0.1:5000\(path) 2>&1; true"],
            workingDirectory: nil)
        return result.stdout
    }

    private static func waitUntilServing(_ backend: CLIBackend, _ container: String) async throws {
        for _ in 0..<60 {
            let answer = (try? await get(backend, container, "/v2/")) ?? ""
            if answer.contains("{}") || answer.contains("401") { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("the registry in \(container) did not start serving within 30 s")
    }

    /// A temporary folder holding an `htpasswd` file for `user` and `password` (bcrypt). `nil` when this Mac
    /// has no `/usr/sbin/htpasswd`. The password goes to `htpasswd` on stdin, never in its arguments.
    static func makeHtpasswdFolder(password: String) async throws -> URL? {
        let tool = "/usr/sbin/htpasswd"
        guard FileManager.default.isExecutableFile(atPath: tool) else { return nil }
        let result = try await ProcessRunner().run(
            [tool, "-Bni", user], stdin: Data((password + "\n").utf8), timeout: .seconds(30))
        guard result.exitCode == 0, result.stdoutText.hasPrefix("\(user):$2") else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: Integration.uniqueName("reg-auth"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try result.stdout.write(to: folder.appending(path: "htpasswd"))
        return folder
    }

    /// A TCP port on this Mac that nothing listens on (bound once to learn a free number, then released).
    static func closedPort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    /// The command lines of every process on this Mac right now. Only ever searched, never printed.
    static func processCommandLines() async throws -> [String] {
        let result = try await ProcessRunner().run(["/bin/ps", "-axww", "-o", "command="], timeout: .seconds(30))
        return result.stdoutText.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// `server` and `username` of each login, sorted: what must be the same before and after a test.
    static func loginSnapshot(_ backend: CLIBackend) async throws -> [String] {
        try await backend.listRegistries().map { "\($0.server) \($0.username ?? "")" }.sorted()
    }
}
