import Foundation
import Testing

@testable import ContainerKit

/// `image push`, `image pull --scheme http`, `registry login` / `logout` / `list` against the real `container`
/// CLI and a throwaway `registry:2` container (`ThrowawayRegistry`). Run with:
/// `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`.
///
/// Everything created is named `cd-it-reg-…` and removed again. The only registry host that is logged in to or
/// out of is the address of the container the test started; the logins that existed before are compared with
/// the ones afterwards. Each test returns early when the registry image cannot be pulled.
///
/// What this cannot cover: a login that *succeeds against a registry asking for one*. container 1.7.1 refuses
/// to answer an authentication challenge over plain HTTP, and HTTPS needs a certificate this Mac trusts.
@Suite("Registry Integration", .serialized, .enabled(if: Integration.isEnabled, Integration.hint))
struct RegistryIntegrationTests {
    let backend: CLIBackend

    init() throws {
        backend = try CLIBackend()
    }

    /// Drains a stream, remembering when each line arrived.
    private func timed(_ stream: LineStream) async -> (lines: [(text: String, at: Date)], error: BackendError?) {
        var lines: [(text: String, at: Date)] = []
        do {
            for try await line in stream { lines.append((line.text, Date())) }
            return (lines, nil)
        } catch {
            return (lines, error as? BackendError ?? .other(String(describing: error)))
        }
    }

    private func message(_ error: BackendError?) -> String { error?.errorDescription ?? "" }

    /// Runs `body` when the registry image is local or can be pulled, and removes the image again when this
    /// call was the one that pulled it. Without the image nothing is tested.
    private func withRegistryImage(_ body: () async throws -> Void) async throws {
        guard let pulled = await ThrowawayRegistry.ensureImage(backend) else { return }
        do {
            try await body()
        } catch {
            if pulled { try? await backend.deleteImage(ThrowawayRegistry.image) }
            throw error
        }
        if pulled { try? await backend.deleteImage(ThrowawayRegistry.image) }
    }

    // MARK: Push and pull, no authentication

    @Test(.timeLimit(.minutes(10)))
    func pushesAndPullsBackOverPlainHTTP() async throws {
        try await withRegistryImage {
            try await ThrowawayRegistry.with(backend) { host, registry in
                let reference = "\(host)/cd-it-reg/alpine:test"
                try await backend.tagImage(Integration.busyBoxImage, newReference: reference)
                do {
                    try await pushPullAndRun(reference, host: host, registry: registry)
                    try? await backend.deleteImage(reference)
                } catch {
                    try? await backend.deleteImage(reference)
                    throw error
                }
            }
        }
    }

    private func pushPullAndRun(_ reference: String, host: String, registry: String) async throws {
        // 1. The CLI's default scheme is HTTPS and the registry serves HTTP. The CLI retries for about 40 s,
        //    printing a progress line each second: those must arrive while it runs, and the failure must say
        //    what to change.
        let wrong = await timed(backend.pushImage(reference, platform: .arm64, scheme: nil))
        #expect(message(wrong.error).hasPrefix("\(host) did not answer with HTTPS."), "\(message(wrong.error))")
        #expect(message(wrong.error).contains("choose HTTP as the connection"))
        #expect(!message(wrong.error).contains("Pushing image"), "progress lines leaked into the error")
        #expect(wrong.lines.count >= 5, "only \(wrong.lines.count) progress lines")
        if let first = wrong.lines.first, let last = wrong.lines.last {
            #expect(last.at.timeIntervalSince(first.at) > 5, "the lines arrived together, not as they were printed")
        }

        // 2. Every platform of an image that was pulled for this Mac only cannot be pushed. Whether the local
        //    alpine is such an image depends on the Mac, so only the wording of a failure is checked.
        let all = await timed(backend.pushImage(reference, platform: nil, scheme: "http"))
        if let error = all.error { #expect(message(error).contains("Choose a single platform"), "\(message(error))") }

        // 3. The push that works.
        let pushed = await timed(backend.pushImage(reference, platform: .arm64, scheme: "http"))
        #expect(pushed.error == nil, "\(message(pushed.error))")
        #expect(pushed.lines.contains { $0.text.contains("Pushing image \(reference)") })
        #expect(pushed.lines.contains { $0.text == reference })  // stdout: the pushed reference
        #expect(try await ThrowawayRegistry.get(backend, registry, "/v2/_catalog").contains("cd-it-reg/alpine"))

        // 4. Remove the local tag, pull it back, run it.
        try await backend.deleteImage(reference)
        #expect(try await !backend.listImages().contains { $0.reference == reference })
        let pulledBack = await timed(backend.pullImage(reference, platform: .arm64, scheme: "http"))
        #expect(pulledBack.error == nil, "\(message(pulledBack.error))")
        #expect(try await backend.listImages().contains { $0.reference == reference })
        var spec = RunSpec(image: reference)
        spec.name = Integration.uniqueName("reg-run")
        spec.detach = false
        spec.removeOnExit = true
        spec.command = ["echo", "ran from the registry"]
        var output: [String] = []
        do {
            for try await line in backend.runContainer(spec) where line.stream == .stdout { output.append(line.text) }
        } catch {
            try? await backend.deleteContainer(spec.name ?? "", force: true)
            throw error
        }
        #expect(output.contains("ran from the registry"))
    }

    /// Nothing listens on the port: the CLI's `POSIXErrorCode(rawValue: 61)` becomes a sentence.
    @Test(.timeLimit(.minutes(5)))
    func aRegistryThatIsNotThereIsNamed() async throws {
        let port = try #require(ThrowawayRegistry.closedPort())
        let host = "127.0.0.1:\(port)"
        let reference = "\(host)/cd-it-reg/alpine:test"
        try await backend.tagImage(Integration.busyBoxImage, newReference: reference)
        let result = await timed(backend.pushImage(reference, platform: .arm64, scheme: "http"))
        try? await backend.deleteImage(reference)
        #expect(message(result.error).hasPrefix("Nothing answers at \(host) (connection refused)."))
        #expect(message(result.error).contains("Connection refused"), "the CLI's own words are kept")
        guard case .commandFailed(let command, _, _) = result.error else {
            Issue.record("expected commandFailed, got \(String(describing: result.error))")
            return
        }
        #expect(command.contains("image push --scheme http --progress plain --platform linux/arm64 -- \(reference)"))
    }

    // MARK: Login

    /// Login through stdin, the listing, a push with the stored login, logout. The registry asks for no
    /// authentication, which is the only kind container 1.7.1 logs in to over plain HTTP.
    @Test(.timeLimit(.minutes(10)))
    func logsInThroughStdinListsAndLogsOut() async throws {
        let before = try await ThrowawayRegistry.loginSnapshot(backend)
        let secret = UUID().uuidString + UUID().uuidString
        try await withRegistryImage {
            try await ThrowawayRegistry.with(backend) { host, _ in
                do {
                    try await loginListPushLogout(host: host, secret: secret)
                    try? await backend.registryLogout(server: host)
                } catch {
                    try? await backend.registryLogout(server: host)
                    throw error
                }
            }
        }
        let unchanged = try await ThrowawayRegistry.loginSnapshot(backend) == before
        #expect(unchanged, "the logins on this Mac changed")
    }

    private func loginListPushLogout(host: String, secret: String) async throws {
        // 1. Over HTTPS the CLI retries for about 40 s. Long enough to look at the process table: the login
        //    command is there, the password is not.
        async let slow = Integration.backendError {
            try await backend.registryLogin(
                server: host, username: ThrowawayRegistry.user, password: secret, scheme: nil)
        }
        try await Task.sleep(for: .seconds(4))
        let processes = try await ThrowawayRegistry.processCommandLines()
        let loginSeen = processes.contains { $0.contains("registry login") && $0.contains(host) }
        let secretInArguments = processes.contains { $0.contains(secret) }
        #expect(loginSeen, "the login was not running when the process table was read")
        #expect(!secretInArguments, "the password is visible in a process's arguments")
        let slowError = await slow
        // Booleans only from here on: a failed expectation prints its operands, and none may hold the password.
        let slowExplained = (slowError?.errorDescription ?? "").hasPrefix("\(host) did not answer with HTTPS.")
        let slowLeaked = String(describing: slowError).contains(secret)
        #expect(slowExplained, "a login over the wrong scheme was not explained")
        #expect(!slowLeaked, "the password is in the error")

        // 2. Over HTTP it succeeds, and the listing has the shape the model reads.
        try await backend.registryLogin(
            server: host, username: ThrowawayRegistry.user, password: secret, scheme: "http")
        let login = try #require(try await backend.listRegistries().first { $0.server == host })
        #expect(login.username == ThrowawayRegistry.user)
        let raw = try await backend.execute(["registry", "ls", "--format", "json"])
        let rawHasSecret = raw.stdoutText.contains(secret) || raw.stderrText.contains(secret)
        #expect(!rawHasSecret, "`registry list` printed the password")
        let records = try JSONDecoder().decode([[String: JSONValue]].self, from: raw.stdout)
        let record = try #require(records.first { $0["name"]?.stringValue == host })
        #expect(Set(record.keys) == ["creationDate", "id", "labels", "modificationDate", "name", "username"])
        #expect(record["id"]?.stringValue == host)

        // 3. A push with the login stored.
        let reference = "\(host)/cd-it-reg/alpine:login"
        try await backend.tagImage(Integration.busyBoxImage, newReference: reference)
        let pushed = await timed(backend.pushImage(reference, platform: .arm64, scheme: "http"))
        try? await backend.deleteImage(reference)
        #expect(pushed.error == nil, "\(message(pushed.error))")

        // 4. Logout removes exactly that entry; a second logout is not an error.
        try await backend.registryLogout(server: host)
        #expect(try await !backend.listRegistries().contains { $0.server == host })
        try await backend.registryLogout(server: host)
    }

    /// A registry that asks for a password, over plain HTTP: container refuses to send one, whatever the
    /// password is. The refusal must read as advice and must not carry the password.
    @Test(.timeLimit(.minutes(10)))
    func aLoginOverPlainHTTPIsRefusedWithAdvice() async throws {
        let before = try await ThrowawayRegistry.loginSnapshot(backend)
        let secret = UUID().uuidString + UUID().uuidString
        guard let folder = try await ThrowawayRegistry.makeHtpasswdFolder(password: secret) else { return }
        defer { try? FileManager.default.removeItem(at: folder) }
        try await withRegistryImage {
            try await ThrowawayRegistry.with(backend, htpasswdFolder: folder) { host, registry in
                #expect(try await ThrowawayRegistry.get(backend, registry, "/v2/").contains("401"))
                for password in [secret, "not-the-password-" + UUID().uuidString] {
                    let error = await Integration.backendError {
                        try await backend.registryLogin(
                            server: host, username: ThrowawayRegistry.user, password: password, scheme: "http")
                    }
                    // Booleans only: a failed expectation prints its operands, and none may hold the password.
                    let text = error?.errorDescription ?? ""
                    let explained =
                        text.hasPrefix("\(host) asks for a login, and container does not send credentials")
                        && text.contains("Log in over HTTPS")
                    let leaked = String(describing: error).contains(password)
                    #expect(explained, "the refusal was not explained")
                    #expect(!leaked, "the password is in the error")
                }
                #expect(try await !backend.listRegistries().contains { $0.server == host })

                let reference = "\(host)/cd-it-reg/alpine:auth"
                try await backend.tagImage(Integration.busyBoxImage, newReference: reference)
                let pushed = await timed(backend.pushImage(reference, platform: .arm64, scheme: "http"))
                try? await backend.deleteImage(reference)
                #expect(message(pushed.error).contains("Use HTTPS for a registry that needs a login"))
                try? await backend.registryLogout(server: host)
            }
        }
        let unchanged = try await ThrowawayRegistry.loginSnapshot(backend) == before
        #expect(unchanged, "the logins on this Mac changed")
    }
}
