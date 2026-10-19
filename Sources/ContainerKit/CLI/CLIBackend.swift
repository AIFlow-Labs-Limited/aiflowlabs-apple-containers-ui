import Foundation
import os

/// Backend that drives the `container` CLI (`/usr/local/bin/container`), using `--format json` wherever the
/// CLI offers it and parsing tables elsewhere. It keeps no state; stores cache.
///
/// Operations live in per-area extensions (`CLIBackend+Containers.swift`, `+Images`, …). Every command goes
/// through the injected `CommandRunning`, so tests can record the exact argv.
public actor CLIBackend: ContainerBackend {
    /// Where the CLI is looked for when neither an explicit path nor `$CONTAINER_CLI` is given.
    public static let defaultSearchPaths = ["/usr/local/bin/container", "/opt/homebrew/bin/container"]

    /// Absolute path of the `container` executable.
    public let executable: String
    /// Runs every child process.
    public let runner: any CommandRunning
    /// Explicit `config.toml` location; `nil` means `$CONTAINER_CONFIG_PATH` or `~/.config/container/config.toml`.
    public let configPath: String?

    /// Default timeout for quick, read-only commands (`ls`, `inspect`, …).
    static let queryTimeout: Duration = .seconds(60)
    /// Default timeout for state-changing commands that should finish promptly (`stop`, `rm`, …).
    static let actionTimeout: Duration = .seconds(180)
    /// Timeout for `prune` commands, which can delete many large images or volumes.
    static let pruneTimeout: Duration = .seconds(15 * 60)

    /// Diagnostics name, e.g. `CLI (/usr/local/bin/container)`.
    public nonisolated var backendDescription: String { "CLI (\(executable))" }

    /// Creates a CLI backend.
    /// - Parameters:
    ///   - executable: explicit path; defaults to `$CONTAINER_CLI` or the first existing search path.
    ///   - runner: process runner (inject a fake in tests).
    ///   - configPath: `config.toml` override (tests); defaults to `$CONTAINER_CONFIG_PATH` / `~/.config/container/config.toml`.
    /// - Throws: `BackendError.cliNotInstalled` when no executable is found.
    public init(
        executable: String? = nil, runner: any CommandRunning = ProcessRunner(), configPath: String? = nil
    ) throws {
        self.runner = runner
        self.configPath = configPath
        if let executable { self.executable = executable; return }
        guard let found = CLIBackend.locateExecutable() else {
            throw BackendError.cliNotInstalled(searchedPaths: CLIBackend.searchPaths())
        }
        self.executable = found
    }

    /// Where `locateExecutable` looks: only `$CONTAINER_CLI` when it is set, else `defaultSearchPaths`.
    public static func searchPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if let env = environment["CONTAINER_CLI"], !env.isEmpty { return [env] }
        return defaultSearchPaths
    }

    /// `$CONTAINER_CLI` when set (and only it: a wrong override reports "not installed" instead of silently
    /// running a different binary), else the first executable entry of `defaultSearchPaths`.
    public static func locateExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        searchPaths(environment: environment).first(where: isExecutable)
    }

    /// Command line an embedded terminal should spawn for an interactive session.
    public nonisolated func terminalCommand(for target: TerminalTarget) -> CommandLine {
        switch target {
        case .container(let id, let command):
            return CommandLine(executable: executable, arguments: ["exec", "-it", "--", id] + command)
        case .machine(let name): return CommandLine(executable: executable, arguments: ["machine", "run", "-n", name])
        case .shell: return CommandLine(executable: "/bin/zsh", arguments: ["-l"])
        }
    }

    // MARK: - Command helpers

    /// Shell-quoted command line for error messages and "copy command".
    nonisolated func display(_ arguments: [String]) -> String {
        CommandLine(executable: executable, arguments: arguments).display
    }

    /// Runs `container <arguments>` and returns the raw result without interpreting the exit code.
    nonisolated func runRaw(
        _ arguments: [String], stdin: Data? = nil, timeout: Duration? = queryTimeout
    ) async throws -> ProcessResult {
        do {
            return try await runner.run([executable] + arguments, stdin: stdin, timeout: timeout, environment: [:])
        } catch let error as BackendError {
            throw error
        } catch is CancellationError {
            throw BackendError.cancelled
        } catch {
            throw BackendError.other(error.localizedDescription)
        }
    }

    /// Runs `container <arguments>`; a non-zero exit throws the mapped `BackendError`.
    @discardableResult
    nonisolated func execute(
        _ arguments: [String], stdin: Data? = nil, timeout: Duration? = queryTimeout
    ) async throws -> ProcessResult {
        let result = try await runRaw(arguments, stdin: stdin, timeout: timeout)
        guard result.exitCode == 0 else { throw await failure(arguments, result) }
        return result
    }

    /// Runs a JSON-producing command and decodes its stdout.
    nonisolated func decode<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
        let result = try await execute(arguments)
        do {
            return try CLIJSON.decode(type, from: result.stdout)
        } catch {
            throw BackendError.decoding(command: display(arguments), underlying: String(describing: error))
        }
    }

    /// Decodes a `ls`-style JSON array leniently: elements that fail to decode are skipped and logged.
    nonisolated func decodeList<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> [T] {
        let list = try await decode(LossyArray<T>.self, arguments)
        if list.droppedCount > 0 {
            let command = display(arguments)
            let reasons = list.errors.prefix(3).joined(separator: " | ")
            Self.log.error(
                "Skipped \(list.droppedCount, privacy: .public) undecodable element(s) from `\(command, privacy: .public)`: \(reasons, privacy: .public)"
            )
        }
        return list.elements
    }

    static let log = Logger(subsystem: "io.aiflowlabs.containerdesktop", category: "CLIBackend")

    /// Decodes an `inspect`-style JSON array and returns its first element (`notFound` when empty).
    nonisolated func inspectFirst<T: Decodable>(
        _ type: T.Type, kind: String, id: String, _ arguments: [String]
    ) async throws -> T {
        guard let first = try await decode([T].self, arguments).first else {
            throw BackendError.notFound(kind: kind, id: id)
        }
        return first
    }

    /// Maps a failed result, probing `system status` to disambiguate `Plugins are unavailable`.
    nonisolated func failure(_ arguments: [String], _ result: ProcessResult) async -> BackendError {
        let mapped = CLIErrorMapper.map(
            command: display(arguments), exitCode: result.exitCode, stderr: result.stderrText, stdout: result.stdoutText
        )
        return await refine(mapped, arguments: arguments, rawOutput: result.stderrText + result.stdoutText)
    }

    /// Upgrades an ambiguous `commandFailed` to `.systemNotRunning` when `system status` also fails.
    nonisolated func refine(_ error: BackendError, arguments: [String], rawOutput: String) async -> BackendError {
        guard case .commandFailed = error, CLIErrorMapper.isPluginsUnavailable(rawOutput),
            Array(arguments.prefix(2)) != ["system", "status"]
        else { return error }
        let status = try? await runner.run(
            [executable, "system", "status"], stdin: nil, timeout: .seconds(15), environment: [:])
        return status?.exitCode == 0 ? error : .systemNotRunning
    }

    /// Streams `container <arguments>`, remapping a failure to the most specific `BackendError`.
    nonisolated func streamCommand(_ arguments: [String]) -> LineStream {
        let upstream = runner.stream([executable] + arguments, environment: [:])
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(ProcessRunner.streamBufferLimit)) { continuation in
            let task = Task {
                do {
                    for try await line in upstream { continuation.yield(line) }
                    continuation.finish()
                } catch BackendError.commandFailed(let command, let code, let message) {
                    let mapped = CLIErrorMapper.map(command: command, exitCode: code, stderr: message)
                    continuation.finish(throwing: await self.refine(mapped, arguments: arguments, rawOutput: message))
                } catch is CancellationError {
                    continuation.finish(throwing: BackendError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A stream that immediately fails (unsupported option combinations).
    nonisolated func failedStream(_ error: BackendError) -> LineStream {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }

    /// Rejects a name, id or reference that the CLI would parse as an option. Positional operands are also
    /// passed after `--`; this keeps option *values* (`--name X`) and error messages unambiguous.
    static func validateOperand(_ value: String, _ what: String) throws {
        guard !value.hasPrefix("-") else {
            throw BackendError.other("\(what) “\(value)” may not start with -")
        }
    }

    /// `validateOperand` for several values.
    static func validateOperands(_ values: [String], _ what: String) throws {
        for value in values { try validateOperand(value, what) }
    }

    /// Runs `body` to build a stream, turning a validation error into a stream that fails immediately.
    nonisolated func validatedStream(_ body: () throws -> LineStream) -> LineStream {
        do { return try body() } catch let error as BackendError { return failedStream(error) } catch {
            return failedStream(.other(error.localizedDescription))
        }
    }

    /// Appends `--label key=value` pairs sorted by key (stable argv for tests and "copy command").
    static func labelArguments(_ labels: [String: String], flag: String = "--label") -> [String] {
        labels.sorted { $0.key < $1.key }.flatMap { [flag, "\($0.key)=\($0.value)"] }
    }

    /// Splits stdout into non-empty lines.
    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map(String.init).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
}
