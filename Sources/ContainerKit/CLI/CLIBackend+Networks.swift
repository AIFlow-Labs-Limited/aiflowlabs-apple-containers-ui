import Foundation

// MARK: - NetworkOperations

extension CLIBackend {
    /// `container network ls --format json`.
    public func listNetworks() async throws -> [Network] {
        try await decodeList(Network.self, ["network", "ls", "--format", "json"])
    }

    /// `container network inspect -- NAME` (one-element array).
    public func inspectNetwork(_ name: String) async throws -> Network {
        try Self.validateOperand(name, "Network name")
        return try await inspectFirst(Network.self, kind: "network", id: name, ["network", "inspect", "--", name])
    }

    /// `container network create [--subnet CIDR] [--subnet-v6 CIDR] [--label k=v]… -- NAME`.
    public func createNetwork(name: String, subnet: String?, subnetV6: String?, labels: [String: String]) async throws {
        try Self.validateOperand(name, "Network name")
        var arguments = ["network", "create"]
        if let subnet { arguments += ["--subnet", subnet] }
        if let subnetV6 { arguments += ["--subnet-v6", subnetV6] }
        arguments += Self.labelArguments(labels)
        arguments += ["--", name]
        try await execute(arguments)
    }

    /// `container network rm -- NAME`.
    public func deleteNetwork(_ name: String) async throws {
        try Self.validateOperand(name, "Network name")
        try await execute(["network", "rm", "--", name], timeout: Self.actionTimeout)
    }

    /// `container network prune`.
    public func pruneNetworks() async throws {
        try await execute(["network", "prune"], timeout: Self.pruneTimeout)
    }
}
