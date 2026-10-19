import Foundation

// MARK: - SystemBackend

extension CLIBackend {
    /// `container system status --format json`. When the apiserver is down this returns a `stopped` status
    /// carrying the client version (from `container --version`) instead of throwing.
    public func systemStatus() async throws -> SystemStatus {
        let arguments = ["system", "status", "--format", "json"]
        let result = try await runRaw(arguments)
        if result.exitCode == 0 {
            do {
                return try CLIJSON.decode(SystemStatus.self, from: result.stdout)
            } catch {
                throw BackendError.decoding(command: display(arguments), underlying: String(describing: error))
            }
        }
        let error = CLIErrorMapper.map(command: display(arguments), exitCode: result.exitCode,
                                       stderr: result.stderrText, stdout: result.stdoutText)
        // A failing `system status` is itself the authoritative "services are down" signal.
        if error == .systemNotRunning || CLIErrorMapper.isPluginsUnavailable(result.stderrText + result.stdoutText) {
            return .stopped(clientVersion: await clientVersion())
        }
        throw error
    }

    /// The CLI's own version (`container --version`), available even when services are down.
    public func clientVersion() async -> String? {
        guard let result = try? await runRaw(["--version"], timeout: .seconds(15)), result.exitCode == 0 else { return nil }
        return CLIOutputParsing.cliVersion(result.stdoutText)
    }

    /// `container system start --enable-kernel-install` (never prompts on a TTY).
    public func systemStart() async throws {
        try await execute(["system", "start", "--enable-kernel-install"], timeout: .seconds(300))
    }

    /// `container system stop`.
    public func systemStop() async throws {
        try await execute(["system", "stop"], timeout: Self.actionTimeout)
    }

    /// `container system property ls --format json`.
    public func systemProperties() async throws -> SystemProperties {
        try await decode(SystemProperties.self, ["system", "property", "ls", "--format", "json"])
    }

    /// `container system df --format json`.
    public func diskUsage() async throws -> DiskUsage {
        try await decode(DiskUsage.self, ["system", "df", "--format", "json"])
    }

    /// The last `lines` lines of `container system logs --last WINDOW`; the window grows with the request
    /// (≤ 500 lines → `5m`, else `1h`) so a small request never buffers an hour of logs.
    public func systemLogs(lines: Int) async throws -> [OutputLine] {
        let window = lines <= 500 ? "5m" : "1h"
        let result = try await execute(["system", "logs", "--last", window])
        return Self.lines(result.stdoutText).suffix(max(0, lines)).map { OutputLine($0) }
    }

    /// `container system dns ls --format json` (lenient decoding; falls back to the table).
    public func listDNSDomains() async throws -> [DNSDomain] {
        let result = try await execute(["system", "dns", "ls", "--format", "json"])
        return CLIOutputParsing.dnsDomains(result.stdout)
    }

    /// `container system dns create [--localhost IP] -- DOMAIN`, run as administrator through `osascript`.
    public func createDNSDomain(_ domain: String, localhostAddress: String?) async throws {
        try Self.validateDomain(domain)
        var arguments = ["system", "dns", "create"]
        if let localhostAddress {
            guard !localhostAddress.isEmpty, localhostAddress.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == ":" }) else {
                throw BackendError.other("“\(localhostAddress)” is not a valid IP address.")
            }
            arguments += ["--localhost", localhostAddress]
        }
        arguments += ["--", domain]
        try await runAsAdministrator(arguments)
    }

    /// `container system dns delete -- DOMAIN`, run as administrator through `osascript`.
    public func deleteDNSDomain(_ domain: String) async throws {
        try Self.validateDomain(domain)
        try await runAsAdministrator(["system", "dns", "delete", "--", domain])
    }

    /// Raw `config.toml`, or `""` when the file does not exist.
    public func readConfigTOML() async throws -> String {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BackendError.other("Could not read \(url.path): \(error.localizedDescription)")
        }
    }

    /// Writes `config.toml` atomically, creating its directory when needed. A symlinked config (dotfiles)
    /// is written through to its target, and the existing file's POSIX permissions are kept.
    public func writeConfigTOML(_ text: String) async throws {
        let url = configFileURL.resolvingSymlinksInPath()
        let fm = FileManager.default
        do {
            let permissions = (try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions]
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        } catch {
            throw BackendError.other("Could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// The `config.toml` this backend reads and writes.
    public nonisolated var configFileURL: URL {
        if let configPath { return URL(fileURLWithPath: configPath) }
        return Self.configFileURL(environment: ProcessInfo.processInfo.environment)
    }

    /// `$CONTAINER_CONFIG_PATH` if set, else `~/.config/container/config.toml`.
    public static func configFileURL(environment: [String: String]) -> URL {
        if let override = environment["CONTAINER_CONFIG_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/container/config.toml")
    }

    // MARK: Administrator helpers

    /// The `osascript` argv that runs `container <arguments>` with administrator privileges.
    nonisolated func administratorCommand(_ arguments: [String]) -> [String] {
        let shell = ([executable] + arguments).map(Self.shellQuote).joined(separator: " ")
        let appleScriptLiteral = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ["/usr/bin/osascript", "-e", "do shell script \"\(appleScriptLiteral)\" with administrator privileges"]
    }

    private func runAsAdministrator(_ arguments: [String]) async throws {
        let command = administratorCommand(arguments)
        let result = try await runner.run(command, stdin: nil, timeout: nil, environment: [:])
        guard result.exitCode == 0 else {
            let raw = result.stderrText
            if CLIErrorMapper.indicatesUserCancelled(raw) { throw BackendError.cancelled }
            // osascript wraps the shell error: "0:123: execution error: Error: … (1)".
            var message = CLIErrorMapper.cleanMessage(raw)
            if let range = message.range(of: "execution error: ") { message = String(message[range.upperBound...]) }
            if message.hasPrefix("Error: ") { message = String(message.dropFirst("Error: ".count)) }
            throw BackendError.commandFailed(command: display(arguments), exitCode: result.exitCode, message: message)
        }
    }

    static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func validateDomain(_ domain: String) throws {
        try validateOperand(domain, "DNS domain")
        let valid = !domain.isEmpty && domain.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "." }
        guard valid else { throw BackendError.other("“\(domain)” is not a valid DNS domain name.") }
    }
}
