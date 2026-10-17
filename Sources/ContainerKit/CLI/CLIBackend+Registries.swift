import Foundation

// MARK: - RegistryOperations

extension CLIBackend {
    /// `container registry ls --format json` (lenient decoding; falls back to the table).
    public func listRegistries() async throws -> [RegistryLogin] {
        let result = try await execute(["registry", "ls", "--format", "json"])
        return CLIOutputParsing.registries(result.stdout)
    }

    /// `container registry login [--scheme S] --username U --password-stdin SERVER`.
    /// The password is written to stdin followed by a newline; it never appears in argv.
    public func registryLogin(server: String, username: String, password: String, scheme: String?) async throws {
        try await execute(Self.loginArguments(server: server, username: username, scheme: scheme),
                          stdin: Data((password + "\n").utf8), timeout: Self.actionTimeout)
    }

    /// argv for `registryLogin` (no secret in it).
    static func loginArguments(server: String, username: String, scheme: String?) -> [String] {
        ["registry", "login"] + (scheme.map { ["--scheme", $0] } ?? []) + ["--username", username, "--password-stdin", server]
    }

    /// `container registry logout SERVER`.
    public func registryLogout(server: String) async throws {
        try await execute(["registry", "logout", server])
    }
}
