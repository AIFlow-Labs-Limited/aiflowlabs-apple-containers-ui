import ContainerKit
import Foundation

// Form models for the Kubernetes sheets. What the installed CLI supports comes in as `KubernetesCapabilities`
// (detected by the backend), so the same form drives `container k8s` (1.5/1.6.0) and `container cluster` (1.6.1+).

/// One row of separately sized workers in the "Create cluster" sheet (`--workers count=N,cpus=N,memory=SIZE`).
public struct WorkerGroupForm: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var count: Int
    public var cpus: Int
    public var memoryGB: Int

    public init(id: UUID = UUID(), count: Int = 1, cpus: Int, memoryGB: Int) {
        self.id = id; self.count = count; self.cpus = cpus; self.memoryGB = memoryGB
    }

    /// The spec value for this row.
    public var group: ClusterWorkerGroup {
        ClusterWorkerGroup(count: count, cpus: cpus, memory: MemorySize(bytes: Int64(memoryGB) << 30))
    }
}

/// State of the "Create cluster" sheet. `spec` only ever contains options `capabilities` supports, so a control
/// that is disabled in the sheet can never leak into the command.
public struct ClusterForm: Hashable, Sendable {
    public static let defaultNodeImage = "docker.io/kindest/node:v1.35.5"
    /// Upper bound of the worker steppers (Apple allows 1024 per cluster; a Mac runs out of memory long before).
    public static let maxWorkersPerRow = 16

    public var name: String
    /// Size of the control-plane node (the only node when there are no workers).
    public var cpus: Int
    public var memoryGB: Int
    public var nodeImage = ClusterForm.defaultNodeImage
    public var cniManifestPath = ""
    public var removeOnStop = false
    /// Workers of the default size.
    public var workers = 0
    /// Extra groups of workers with their own size.
    public var sizedWorkers: [WorkerGroupForm] = []
    /// Let nodes use the local image store (see `SharedImageStoreNotes`).
    public var sharedImageStore = false
    /// What the installed CLI's plugin supports; decides the command word and which options are sent.
    public var capabilities: KubernetesCapabilities
    /// Names already taken (from the cluster list), for the duplicate check.
    public var existingNames: [String]

    private let host: HostResources

    public init(
        host: HostResources = .current, capabilities: KubernetesCapabilities = .legacy, existingNames: [String] = []
    ) {
        self.host = host
        self.capabilities = capabilities
        self.existingNames = existingNames
        // Start from the CLI's default name, or the first free `<default>-N` when that one is taken.
        let base = capabilities.defaultClusterName
        name = ([base] + (2...99).map { "\(base)-\($0)" }).first { !existingNames.contains($0) } ?? base
        cpus = host.clusterDefaultCPUs
        memoryGB = host.clusterDefaultMemoryGB
    }

    public var nameError: String? {
        if let error = MachineNameRule.validate(name) { return error }
        if existingNames.contains(name) { return "A cluster named “\(name)” already exists." }
        return nil
    }

    /// Workers the form asks for and the CLI can create.
    public var totalWorkers: Int { spec.totalWorkers }

    /// `nil`, or why the worker rows cannot be created as entered.
    public var workersError: String? {
        totalWorkers > ClusterWorkerGroup.maxWorkers
            ? "A cluster can have at most \(ClusterWorkerGroup.maxWorkers) workers." : nil
    }

    public var isValid: Bool {
        nameError == nil && workersError == nil && !nodeImage.trimmingCharacters(in: .whitespaces).isEmpty
            && spec.unsupportedOption(for: capabilities) == nil
    }

    /// A new sized-workers row, starting at the default node size.
    public mutating func addSizedWorkers() {
        sizedWorkers.append(
            WorkerGroupForm(cpus: host.clusterDefaultCPUs, memoryGB: host.clusterDefaultMemoryGB))
    }

    /// What gets created. Workers, sized groups and the shared image store are left out when the CLI lacks them.
    public var spec: ClusterSpec {
        var s = ClusterSpec(name: name)
        s.cpus = cpus
        s.memory = MemorySize(bytes: Int64(memoryGB) << 30)
        let image = nodeImage.trimmingCharacters(in: .whitespaces)
        s.nodeImage = image == Self.defaultNodeImage ? nil : image
        s.cniManifest = cniManifestPath.isEmpty ? nil : cniManifestPath
        s.removeOnStop = removeOnStop
        if capabilities.supportsWorkers, workers > 0 { s.workers = workers }
        if capabilities.supportsWorkerGroups { s.workerGroups = sizedWorkers.map(\.group).filter { $0.count > 0 } }
        s.sharedImageStore = capabilities.supportsSharedImageStore && sharedImageStore
        return s
    }

    /// The exact command the backend runs for `spec` (`container k8s create …` or `container cluster create …`).
    public func previewCommand(executable: String = "container") -> String {
        let spec = spec
        let arguments =
            (try? spec.createArguments(for: capabilities)) ?? [capabilities.commandWord, "create"] + spec.cliArguments
        return CommandLine(executable: executable, arguments: arguments).display
    }
}

/// Apple's wording about `container cluster create --shared-image-store` (docs/cluster.md in apple/container 1.7.1).
public enum SharedImageStoreNotes {
    /// One line for the toggle.
    public static let summary =
        "Pods can run images you build or pull with container, without a registry. Off by default."

    /// The security warning Apple documents for the option, point by point.
    public static let warnings = [
        "Anything with root on a node, including privileged pods and pods with a hostPath mount, can read every "
            + "image in your local image store, including private images you pulled with your registry credentials.",
        "A local image is used before a registry image with the same name, for every pull policy, and without the "
            + "pod's pull secrets.",
        "Nodes cannot add, change, or delete images in your local image store.",
    ]

    /// How a cluster with the shared store finds images.
    public static let usage =
        "Reference a local image by name in a pod spec (for example my-app:dev). Every pull policy works; after "
        + "rebuilding a tag, use imagePullPolicy: Always or a new tag so the node picks up the new image."

    /// Shown for a cluster created without it.
    public static let off =
        "This cluster was created without the shared image store, so its nodes pull every image from a registry. "
        + "Sharing is set when the cluster is created: to change it, delete the cluster and create it again."
}

/// Copyable kubectl one-liners for a cluster context.
public enum KubectlCommands {
    public static func context(_ cluster: String) -> String { "kubectl --context \(cluster)" }

    /// Quick commands for `cluster`; the `container …` ones use the installed plugin's command word and leave
    /// out `load-image` when the plugin has none.
    public static func quick(
        _ cluster: String, capabilities: KubernetesCapabilities = .legacy
    ) -> [(title: String, command: String)] {
        let k = context(cluster)
        var commands = [
            ("List nodes", "\(k) get nodes -o wide"),
            ("All pods", "\(k) get pods -A"),
            ("Apply a manifest", "\(k) apply -f deploy.yaml"),
        ]
        if capabilities.supportsLoadImage {
            commands.append(
                ("Load a local image", "\(capabilities.displayCommand) load-image --name \(cluster) IMAGE"))
        }
        commands.append(("Delete the cluster", "\(capabilities.displayCommand) delete --name \(cluster)"))
        return commands
    }
}

/// Command preview for the "Load image" sheet.
public enum LoadImageCommand {
    /// `container <word> load-image --name CLUSTER [--platform P] IMAGE`, as shown before running.
    public static func preview(
        cluster: String, reference: String, platform: Platform?, capabilities: KubernetesCapabilities = .legacy,
        executable: String = "container"
    ) -> String {
        var arguments = [capabilities.commandWord, "load-image", "--name", cluster]
        if let platform { arguments += ["--platform", platform.slug] }
        arguments.append(reference.isEmpty ? "IMAGE" : reference)
        return CommandLine(executable: executable, arguments: arguments).display
    }
}
