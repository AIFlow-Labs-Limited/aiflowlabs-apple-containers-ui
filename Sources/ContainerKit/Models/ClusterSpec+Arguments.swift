import Foundation

/// One `--workers` value: `count` workers, optionally with their own CPU count and memory.
public struct ClusterWorkerGroup: Hashable, Sendable {
    /// Apple's limit on the workers of one cluster (`ClusterConfiguration.maxWorkers`).
    public static let maxWorkers = 1024

    public var count: Int
    /// CPUs per worker; `nil` uses the CLI default (a quarter of the host's CPUs, at least 2).
    public var cpus: Int?
    /// Memory per worker; `nil` uses the CLI default (a quarter of the host's memory, at least 2 GB).
    public var memory: MemorySize?

    public init(count: Int, cpus: Int? = nil, memory: MemorySize? = nil) {
        self.count = count; self.cpus = cpus; self.memory = memory
    }

    /// Whether the group sets its own CPU count or memory (needs the `count=…` syntax).
    public var isSized: Bool { cpus != nil || memory != nil }

    /// The option value: `3` for an unsized group, else `count=2,cpus=4,memory=8G`.
    public var cliValue: String {
        guard isSized else { return String(count) }
        var parts = ["count=\(count)"]
        if let cpus { parts.append("cpus=\(cpus)") }
        if let memory { parts.append("memory=\(memory.cliArgument)") }
        return parts.joined(separator: ",")
    }
}

extension ClusterSpec {
    /// `workers` (as one default-sized group) followed by `workerGroups`, without empty groups.
    public var effectiveWorkerGroups: [ClusterWorkerGroup] {
        var groups: [ClusterWorkerGroup] = []
        if let workers, workers > 0 { groups.append(ClusterWorkerGroup(count: workers)) }
        return groups + workerGroups.filter { $0.count > 0 }
    }

    /// Worker nodes the spec asks for, across all groups.
    public var totalWorkers: Int { effectiveWorkerGroups.reduce(0) { $0 + $1.count } }

    /// Why the installed CLI cannot create this spec, or `nil` when it can. Checked before anything runs, so an
    /// unsupported option fails at once instead of minutes into `create`.
    public func unsupportedOption(for capabilities: KubernetesCapabilities) -> BackendError? {
        let groups = effectiveWorkerGroups
        let create = "`\(capabilities.displayCommand) create`"
        if !groups.isEmpty, !capabilities.supportsWorkers {
            return .unsupported(
                feature: "Kubernetes worker nodes", reason: "\(create) has no --workers option in this CLI version.")
        }
        if groups.contains(where: \.isSized), !capabilities.supportsWorkerGroups {
            return .unsupported(
                feature: "Separately sized worker nodes",
                reason:
                    "\(create) takes a worker count only in this CLI version (count=…,cpus=…,memory=… needs 1.7).")
        }
        if totalWorkers > ClusterWorkerGroup.maxWorkers {
            return .unsupported(
                feature: "\(totalWorkers) worker nodes",
                reason: "a cluster may have at most \(ClusterWorkerGroup.maxWorkers) workers.")
        }
        if sharedImageStore, !capabilities.supportsSharedImageStore {
            return .unsupported(
                feature: "The shared image store",
                reason: "\(create) has no --shared-image-store option in this CLI version.")
        }
        return nil
    }

    /// argv after the executable for creating this cluster with a CLI of the given capabilities:
    /// `<word> create --name N [-c N] [-m SIZE] [--node-image REF] [--cni FILE] [--rm] [--workers …]…
    /// [--shared-image-store]`.
    /// - Throws: `BackendError.unsupported` when the spec uses an option the CLI does not have.
    public func createArguments(for capabilities: KubernetesCapabilities) throws -> [String] {
        if let error = unsupportedOption(for: capabilities) { throw error }
        let workers = workerArguments(grouped: capabilities.supportsWorkerGroups)
        return [capabilities.commandWord, "create"] + createOptions(workerArguments: workers)
    }

    /// `--workers` arguments. Unsized groups collapse into one plain count (the form every `--workers` CLI
    /// accepts); as soon as one group is sized, each group is written as its own option when `grouped`.
    func workerArguments(grouped: Bool) -> [String] {
        let groups = effectiveWorkerGroups
        guard !groups.isEmpty else { return [] }
        guard grouped, groups.contains(where: \.isSized) else { return ["--workers", String(totalWorkers)] }
        return groups.flatMap { ["--workers", $0.cliValue] }
    }

    /// The options shared by every CLI version, then the given worker arguments and the image-store flag.
    func createOptions(workerArguments: [String]) -> [String] {
        var a: [String] = ["--name", name]
        if let cpus { a += ["-c", String(cpus)] }
        if let memory { a += ["-m", memory.cliArgument] }
        if let nodeImage { a += ["--node-image", nodeImage] }
        if let cniManifest { a += ["--cni", cniManifest] }
        if removeOnStop { a.append("--rm") }
        a += workerArguments
        if sharedImageStore { a.append("--shared-image-store") }
        return a
    }
}
