import Foundation

// MARK: - RegistryOperations

extension CLIBackend {
    /// `container registry ls --format json` (lenient decoding; falls back to the table).
    public func listRegistries() async throws -> [RegistryLogin] {
        let result = try await execute(["registry", "ls", "--format", "json"])
        return CLIOutputParsing.registries(result.stdout)
    }

    /// `container registry login [--scheme S] --username U --password-stdin -- SERVER`.
    /// The password is written to stdin followed by a newline; it never appears in argv, and the CLI does not
    /// echo it in its errors (checked on 1.7.1). A failure to reach the registry, or its refusal to take
    /// credentials over plain HTTP, is explained by `RegistryFailure`.
    public func registryLogin(server: String, username: String, password: String, scheme: String?) async throws {
        try Self.validateOperand(server, "Registry")
        try Self.validateOperand(username, "User name")
        if let scheme { try Self.validateScheme(scheme) }
        do {
            try await execute(
                Self.loginArguments(server: server, username: username, scheme: scheme),
                stdin: Data((password + "\n").utf8), timeout: Self.actionTimeout)
        } catch {
            throw RegistryFailure.explain(error, host: server, action: .login)
        }
    }

    /// argv for `registryLogin` (no secret in it).
    static func loginArguments(server: String, username: String, scheme: String?) -> [String] {
        ["registry", "login"] + (scheme.map { ["--scheme", $0] } ?? []) + [
            "--username", username, "--password-stdin", "--", server,
        ]
    }

    /// `container registry logout -- SERVER`. The CLI exits 0 for a server that has no login (seen on 1.7.1).
    public func registryLogout(server: String) async throws {
        try Self.validateOperand(server, "Registry")
        try await execute(["registry", "logout", "--", server])
    }
}
