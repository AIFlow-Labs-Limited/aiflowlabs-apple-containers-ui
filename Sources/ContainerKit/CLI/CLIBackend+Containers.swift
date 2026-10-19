import Foundation

// MARK: - ContainerOperations

extension CLIBackend {
    /// `container ls [-a] --format json`.
    public func listContainers(includeStopped: Bool) async throws -> [Container] {
        try await decodeList(Container.self, ["ls"] + (includeStopped ? ["-a"] : []) + ["--format", "json"])
    }

    /// `container inspect -- ID` (the CLI returns a one-element array).
    public func inspectContainer(_ id: String) async throws -> Container {
        try Self.validateOperand(id, "Container")
        return try await inspectFirst(Container.self, kind: "container", id: id, ["inspect", "--", id])
    }

    /// `container run --progress plain …`. With `detach` the last stdout line is the new container id.
    public nonisolated func runContainer(_ spec: RunSpec) -> LineStream {
        validatedStream {
            try Self.validate(spec)
            return streamCommand(Self.runArguments(spec))
        }
    }

    /// Image and name must not look like options.
    static func validate(_ spec: RunSpec) throws {
        try validateOperand(spec.image, "Image reference")
        if let name = spec.name { try validateOperand(name, "Container name") }
    }

    /// argv after the executable for `runContainer`.
    static func runArguments(_ spec: RunSpec) -> [String] {
        ["run", "--progress", "plain"] + spec.cliArguments
    }

    /// `container create …`; returns the id printed on the last stdout line.
    /// Throws `.decoding` when the CLI printed no id and the spec has no name.
    public func createContainer(_ spec: RunSpec) async throws -> String {
        try Self.validate(spec)
        let arguments = Self.createArguments(spec)
        let result = try await execute(arguments, timeout: nil)
        if let id = Self.lines(result.stdoutText).last?.trimmingCharacters(in: .whitespaces), !id.isEmpty { return id }
        if let name = spec.name, !name.isEmpty { return name }
        throw BackendError.decoding(
            command: display(arguments), underlying: "The CLI did not print the new container's id.")
    }

    /// argv after the executable for `createContainer` (`-d` is meaningless for `create` and dropped).
    static func createArguments(_ spec: RunSpec) -> [String] {
        var arguments = spec.cliArguments
        if spec.detach, arguments.first == "-d" { arguments.removeFirst() }
        return ["create"] + arguments
    }

    /// `container start -- ID`.
    public func startContainer(_ id: String) async throws {
        try Self.validateOperand(id, "Container")
        try await execute(["start", "--", id], timeout: Self.actionTimeout)
    }

    /// `container stop [-t SECONDS] [-s SIGNAL] -- ID`.
    public func stopContainer(_ id: String, timeoutSeconds: Int?, signal: String?) async throws {
        try Self.validateOperand(id, "Container")
        var arguments = ["stop"]
        if let timeoutSeconds { arguments += ["-t", String(timeoutSeconds)] }
        if let signal { arguments += ["-s", signal] }
        arguments += ["--", id]
        // Allow the requested grace period on top of the usual action timeout.
        try await execute(arguments, timeout: Self.actionTimeout + .seconds(timeoutSeconds ?? 0))
    }

    /// `container kill [-s SIGNAL] -- ID`.
    public func killContainer(_ id: String, signal: String?) async throws {
        try Self.validateOperand(id, "Container")
        try await execute(["kill"] + (signal.map { ["-s", $0] } ?? []) + ["--", id], timeout: Self.actionTimeout)
    }

    /// `container delete [-f] -- ID`.
    public func deleteContainer(_ id: String, force: Bool) async throws {
        try Self.validateOperand(id, "Container")
        try await execute(["delete"] + (force ? ["-f"] : []) + ["--", id], timeout: Self.actionTimeout)
    }

    /// `container prune` (removes stopped containers).
    public func pruneContainers() async throws {
        try await execute(["prune"], timeout: Self.pruneTimeout)
    }

    /// `container logs [-f] [--boot] [-n N] -- ID`.
    public nonisolated func containerLogs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> LineStream {
        validatedStream {
            try Self.validateOperand(id, "Container")
            return streamCommand(Self.logsArguments(id, follow: follow, boot: boot, tail: tail))
        }
    }

    /// argv after the executable for `containerLogs`.
    static func logsArguments(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> [String] {
        var arguments = ["logs"]
        if follow { arguments.append("-f") }
        if boot { arguments.append("--boot") }
        if let tail { arguments += ["-n", String(tail)] }
        arguments += ["--", id]
        return arguments
    }

    /// `container stats --no-stream --format json [-- IDS…]`.
    public func containerStats(ids: [String]) async throws -> [ContainerStats] {
        try Self.validateOperands(ids, "Container")
        return try await decodeList(
            ContainerStats.self, ["stats", "--no-stream", "--format", "json"] + (ids.isEmpty ? [] : ["--"] + ids))
    }

    /// `container exec [-w DIR] -- ID COMMAND…`. The command's own non-zero exit and stderr are returned, not
    /// thrown; only CLI-level failures throw: the system is down, or *this* container does not exist.
    public func execCapture(
        _ id: String, command: [String], workingDirectory: String?
    ) async throws
        -> (exitCode: Int32, stdout: String, stderr: String)
    {
        try Self.validateOperand(id, "Container")
        var arguments = ["exec"]
        if let workingDirectory { arguments += ["-w", workingDirectory] }
        arguments += ["--", id] + command
        let result = try await runRaw(arguments, timeout: nil)
        if result.exitCode != 0 {
            let stderr = result.stderrText
            if Self.indicatesContainerMissing(stderr, id: id) { throw BackendError.notFound(kind: "container", id: id) }
            if CLIErrorMapper.indicatesSystemNotRunning(stderr) { throw BackendError.systemNotRunning }
            if CLIErrorMapper.isPluginsUnavailable(stderr), await failure(arguments, result) == .systemNotRunning {
                throw BackendError.systemNotRunning
            }
        }
        return (result.exitCode, result.stdoutText, result.stderrText)
    }

    /// `true` when an `Error: …` line is the CLI's own "container not found" for exactly `id`
    /// (`get failed: container ID not found`, `container with ID ID not found`, `container not found: ID`,
    /// `no such container: ID`), as opposed to output of the program run inside the container.
    static func indicatesContainerMissing(_ stderr: String, id: String) -> Bool {
        let patterns = [
            "container \(id) not found", "container with ID \(id) not found", "container with ID \"\(id)\" not found",
            "container not found: \(id)", "no such container: \(id)",
        ]
        return stderr.split(whereSeparator: \.isNewline).contains { raw in
            let line = LineSplitter.stripANSI(String(raw)).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Error: ") else { return false }
            return patterns.contains { pattern in
                guard let range = line.range(of: pattern) else { return false }
                // The id must end there (so `web` does not match `container web2 not found`).
                return range.upperBound == line.endIndex
                    || !(line[range.upperBound].isLetter || line[range.upperBound].isNumber
                        || "-_.".contains(line[range.upperBound]))
            }
        }
    }

    /// `container copy -- SOURCE DESTINATION` (either side may be `<container>:<path>`).
    public func copy(from source: String, to destination: String) async throws {
        try await execute(["copy", "--", source, destination], timeout: nil)
    }

    /// `container export --output TAR -- ID`.
    public func exportContainer(_ id: String, to tarPath: String) async throws {
        try Self.validateOperand(id, "Container")
        try await execute(["export", "--output", tarPath, "--", id], timeout: nil)
    }
}
