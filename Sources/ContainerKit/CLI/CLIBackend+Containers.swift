import Foundation

// MARK: - ContainerOperations

extension CLIBackend {
    /// `container ls [-a] --format json`.
    public func listContainers(includeStopped: Bool) async throws -> [Container] {
        try await decode([Container].self, ["ls"] + (includeStopped ? ["-a"] : []) + ["--format", "json"])
    }

    /// `container inspect ID` (the CLI returns a one-element array).
    public func inspectContainer(_ id: String) async throws -> Container {
        try await inspectFirst(Container.self, kind: "container", id: id, ["inspect", id])
    }

    /// `container run --progress plain …`. With `detach` the last stdout line is the new container id.
    public nonisolated func runContainer(_ spec: RunSpec) -> LineStream {
        streamCommand(Self.runArguments(spec))
    }

    /// argv after the executable for `runContainer`.
    static func runArguments(_ spec: RunSpec) -> [String] {
        ["run", "--progress", "plain"] + spec.cliArguments
    }

    /// `container create …`; returns the id printed on the last stdout line.
    public func createContainer(_ spec: RunSpec) async throws -> String {
        let result = try await execute(Self.createArguments(spec), timeout: nil)
        guard let id = Self.lines(result.stdoutText).last?.trimmingCharacters(in: .whitespaces) else {
            return spec.name ?? ""
        }
        return id
    }

    /// argv after the executable for `createContainer` (`-d` is meaningless for `create` and dropped).
    static func createArguments(_ spec: RunSpec) -> [String] {
        var arguments = spec.cliArguments
        if spec.detach, arguments.first == "-d" { arguments.removeFirst() }
        return ["create"] + arguments
    }

    /// `container start ID`.
    public func startContainer(_ id: String) async throws {
        try await execute(["start", id], timeout: Self.actionTimeout)
    }

    /// `container stop [-t SECONDS] [-s SIGNAL] ID`.
    public func stopContainer(_ id: String, timeoutSeconds: Int?, signal: String?) async throws {
        var arguments = ["stop"]
        if let timeoutSeconds { arguments += ["-t", String(timeoutSeconds)] }
        if let signal { arguments += ["-s", signal] }
        arguments.append(id)
        // Allow the requested grace period on top of the usual action timeout.
        try await execute(arguments, timeout: Self.actionTimeout + .seconds(timeoutSeconds ?? 0))
    }

    /// `container kill [-s SIGNAL] ID`.
    public func killContainer(_ id: String, signal: String?) async throws {
        try await execute(["kill"] + (signal.map { ["-s", $0] } ?? []) + [id], timeout: Self.actionTimeout)
    }

    /// `container delete [-f] ID`.
    public func deleteContainer(_ id: String, force: Bool) async throws {
        try await execute(["delete"] + (force ? ["-f"] : []) + [id], timeout: Self.actionTimeout)
    }

    /// `container prune` (removes stopped containers).
    public func pruneContainers() async throws {
        try await execute(["prune"], timeout: Self.actionTimeout)
    }

    /// `container logs [-f] [--boot] [-n N] ID`.
    public nonisolated func containerLogs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> LineStream {
        streamCommand(Self.logsArguments(id, follow: follow, boot: boot, tail: tail))
    }

    /// argv after the executable for `containerLogs`.
    static func logsArguments(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> [String] {
        var arguments = ["logs"]
        if follow { arguments.append("-f") }
        if boot { arguments.append("--boot") }
        if let tail { arguments += ["-n", String(tail)] }
        arguments.append(id)
        return arguments
    }

    /// `container stats --no-stream --format json [IDS…]`.
    public func containerStats(ids: [String]) async throws -> [ContainerStats] {
        try await decode([ContainerStats].self, ["stats", "--no-stream", "--format", "json"] + ids)
    }

    /// `container exec [-w DIR] ID COMMAND…`. The command's own non-zero exit is returned, not thrown;
    /// CLI-level failures (system down, unknown container) throw.
    public func execCapture(_ id: String, command: [String], workingDirectory: String?) async throws
        -> (exitCode: Int32, stdout: String, stderr: String)
    {
        var arguments = ["exec"]
        if let workingDirectory { arguments += ["-w", workingDirectory] }
        arguments += [id] + command
        let result = try await runRaw(arguments, timeout: nil)
        if result.exitCode != 0, result.stderrText.hasPrefix("Error: ") {
            let error = await failure(arguments, result)
            switch error {
            case .systemNotRunning, .notFound: throw error
            default: break
            }
        }
        return (result.exitCode, result.stdoutText, result.stderrText)
    }

    /// `container copy SOURCE DESTINATION` (either side may be `<container>:<path>`).
    public func copy(from source: String, to destination: String) async throws {
        try await execute(["copy", source, destination], timeout: nil)
    }

    /// `container export --output TAR ID`.
    public func exportContainer(_ id: String, to tarPath: String) async throws {
        try await execute(["export", "--output", tarPath, id], timeout: nil)
    }
}
