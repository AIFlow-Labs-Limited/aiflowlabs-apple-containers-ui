import Foundation

// MARK: - MachineOperations

extension CLIBackend {
    /// `container machine ls --format json` (this shape lacks `image`/`userSetup`; see `inspectMachine`).
    public func listMachines() async throws -> [Machine] {
        try await decodeList(Machine.self, ["machine", "ls", "--format", "json"])
    }

    /// `container machine inspect -- NAME` (one-element array).
    public func inspectMachine(_ name: String) async throws -> Machine {
        try Self.validateOperand(name, "Machine name")
        return try await inspectFirst(Machine.self, kind: "machine", id: name, ["machine", "inspect", "--", name])
    }

    /// `container machine create [opts] IMAGE`, streamed.
    public nonisolated func createMachine(_ spec: MachineSpec) -> LineStream {
        validatedStream {
            try Self.validateOperand(spec.name, "Machine name")
            try Self.validateOperand(spec.image, "Image reference")
            return streamCommand(["machine", "create"] + spec.cliArguments)
        }
    }

    /// `container machine stop -- NAME`.
    public func stopMachine(_ name: String) async throws {
        try Self.validateOperand(name, "Machine name")
        try await execute(["machine", "stop", "--", name], timeout: Self.actionTimeout)
    }

    /// `container machine rm -- NAME`.
    public func deleteMachine(_ name: String) async throws {
        try Self.validateOperand(name, "Machine name")
        try await execute(["machine", "rm", "--", name], timeout: Self.actionTimeout)
    }

    /// `container machine set-default -- NAME`.
    public func setDefaultMachine(_ name: String) async throws {
        try Self.validateOperand(name, "Machine name")
        try await execute(["machine", "set-default", "--", name])
    }

    /// `container machine set -n NAME key=value…` (keys sorted for a stable argv).
    public func configureMachine(_ name: String, settings: [String: String]) async throws {
        try Self.validateOperand(name, "Machine name")
        try Self.validateOperands(Array(settings.keys), "Machine setting")
        let pairs = settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        try await execute(["machine", "set", "-n", name] + pairs)
    }

    /// `container machine logs -- NAME`.
    public func machineLogs(_ name: String) async throws -> [OutputLine] {
        try Self.validateOperand(name, "Machine name")
        let result = try await execute(["machine", "logs", "--", name])
        return Self.lines(result.stdoutText).map { OutputLine($0) }
    }
}
