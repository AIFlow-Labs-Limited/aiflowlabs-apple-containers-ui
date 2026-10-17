import Foundation

// MARK: - VolumeOperations

extension CLIBackend {
    /// `container volume ls --format json`.
    public func listVolumes() async throws -> [Volume] {
        try await decode([Volume].self, ["volume", "ls", "--format", "json"])
    }

    /// `container volume inspect NAME` (one-element array).
    public func inspectVolume(_ name: String) async throws -> Volume {
        try await inspectFirst(Volume.self, kind: "volume", id: name, ["volume", "inspect", name])
    }

    /// `container volume create [-s SIZE] [--opt journal=…] [--label k=v]… NAME`.
    public func createVolume(name: String, size: MemorySize?, journal: String?, labels: [String: String]) async throws {
        try await execute(Self.volumeCreateArguments(name: name, size: size, journal: journal, labels: labels))
    }

    /// argv for `createVolume`.
    static func volumeCreateArguments(name: String, size: MemorySize?, journal: String?, labels: [String: String]) -> [String] {
        var arguments = ["volume", "create"]
        if let size { arguments += ["-s", size.cliArgument] }
        if let journal { arguments += ["--opt", "journal=\(journal)"] }
        arguments += labelArguments(labels)
        arguments.append(name)
        return arguments
    }

    /// `container volume rm NAME`.
    public func deleteVolume(_ name: String) async throws {
        try await execute(["volume", "rm", name], timeout: Self.actionTimeout)
    }

    /// `container volume prune`.
    public func pruneVolumes() async throws {
        try await execute(["volume", "prune"], timeout: Self.actionTimeout)
    }
}
