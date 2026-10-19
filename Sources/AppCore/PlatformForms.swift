import ContainerKit
import Foundation

// Form models for the Machines / Kubernetes / Registries sheets (features-platform). They live in AppCore so the
// validation, defaults and command previews are unit-testable; the views only bind to them.

/// Host CPU count and RAM, used to bound sliders and compute defaults.
public struct HostResources: Hashable, Sendable {
    public var cpus: Int
    public var memoryBytes: Int64

    public init(cpus: Int, memoryBytes: Int64) {
        self.cpus = max(1, cpus)
        self.memoryBytes = max(1 << 30, memoryBytes)
    }

    /// This Mac.
    public static var current: HostResources {
        HostResources(
            cpus: ProcessInfo.processInfo.activeProcessorCount,
            memoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory))
    }

    /// Whole gigabytes of RAM (rounded down, at least 1).
    public var memoryGB: Int { max(1, Int(memoryBytes >> 30)) }

    /// `container machine create` default: half of host RAM.
    public var machineDefaultMemoryGB: Int { max(1, memoryGB / 2) }

    /// `container k8s create` defaults: ¼ of host CPUs (min 2) and ¼ of host RAM (min 2 GB).
    public var clusterDefaultCPUs: Int { min(cpus, max(2, cpus / 4)) }
    public var clusterDefaultMemoryGB: Int { min(memoryGB, max(2, memoryGB / 4)) }
}

// MARK: - Machines

/// Machine names: letters, digits, `-` and `_`, starting with a letter or digit, no dots (they break DNS names).
public enum MachineNameRule {
    public static let maxLength = 63

    /// `nil` when valid, otherwise a short human-readable reason.
    public static func validate(_ name: String) -> String? {
        if name.isEmpty { return "Enter a name." }
        if name.count > maxLength { return "Use at most \(maxLength) characters." }
        if name.contains(".") { return "Dots aren't allowed in machine names." }
        guard name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_-]*/) != nil else {
            return "Use letters, digits, “-” and “_”, starting with a letter or digit."
        }
        return nil
    }
}

/// A curated machine image with what we know about whether it boots.
public struct MachineImageOption: Identifiable, Hashable, Sendable {
    public enum Support: String, Sendable { case verified, needsSetup, unverified }
    public var id: String { reference }
    public var reference: String
    public var title: String
    public var note: String
    public var support: Support

    public init(reference: String, title: String, note: String, support: Support) {
        self.reference = reference; self.title = title; self.note = note; self.support = support
    }

    /// Images known to boot (or known not to without extra work) on CLI 1.5.0.
    public static let curated: [MachineImageOption] = [
        MachineImageOption(
            reference: "ghcr.io/linuxcontainers/alpine:3.20", title: "Alpine 3.20 — verified",
            note: "Apple's own machine test image. Boots in seconds.", support: .verified),
        MachineImageOption(
            reference: "ubuntu:24.04", title: "Ubuntu 24.04 — needs systemd image",
            note: "Stock Ubuntu has no init. Build the systemd Dockerfile from Apple's machine docs first.",
            support: .needsSetup),
        MachineImageOption(
            reference: "debian:bookworm", title: "Debian 12 — unverified",
            note: "Not tested yet. Needs a real /sbin/init to boot.", support: .unverified),
    ]

    /// The image the create sheet offers instead of a known-broken one.
    public static var verified: MachineImageOption { curated[0] }

    /// Spellings of Docker Hub's `alpine`, shown to the user when one is blocked.
    public static let knownBrokenPatterns = [
        "alpine", "alpine:<tag>", "alpine:latest", "docker.io/alpine:<tag>",
        "docker.io/library/alpine:<tag>", "index.docker.io/library/alpine:<tag>",
    ]

    /// Docker Hub's `alpine` (any tag or digest, any spelling) uses busybox init, which calls a missing
    /// /sbin/openrc and reboots immediately. `ghcr.io/linuxcontainers/alpine` is a different image and boots.
    public static func knownBroken(_ reference: String) -> Bool {
        var r = reference.trimmingCharacters(in: .whitespaces).lowercased()
        if let at = r.firstIndex(of: "@") { r = String(r[..<at]) }
        for prefix in ["index.docker.io/", "registry-1.docker.io/", "docker.io/"] where r.hasPrefix(prefix) {
            r.removeFirst(prefix.count)
            break
        }
        if r.hasPrefix("library/") { r.removeFirst("library/".count) }
        let repository = r.split(separator: ":", maxSplits: 1).first.map(String.init) ?? r
        return repository == "alpine"
    }
}

/// How the home folder is mapped into a machine (`--home-mount`).
public enum HomeMountMode: String, CaseIterable, Identifiable, Sendable {
    case readWrite = "rw", readOnly = "ro", none
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .readWrite: return "Read-write"
        case .readOnly: return "Read-only"
        case .none: return "Not mounted"
        }
    }
    public var explanation: String {
        switch self {
        case .readWrite:
            return "Your home folder appears at the same path inside the machine. Changes there change your Mac."
        case .readOnly: return "The machine can read your home folder but can't change it."
        case .none: return "The machine only sees its own disk."
        }
    }
}

/// State of the "Create machine" sheet. `spec` is what gets created; `previewCommand` mirrors it exactly.
public struct MachineForm: Hashable, Sendable {
    public var name = "dev"
    public var image = MachineImageOption.curated[0].reference
    public var cpus: Int
    public var memoryGB: Int
    public var homeMount: HomeMountMode = .readWrite
    public var setDefault = false
    public var bootNow = true
    public var virtualization = false
    public var kernelPath = ""
    /// Names already taken (from `machine ls`), for the duplicate check.
    public var existingNames: [String] = []

    // No user / UID / GID fields: CLI 1.5.0's `machine create` has no `--user` (it always uses your Mac account).

    public init(host: HostResources = .current, existingNames: [String] = []) {
        cpus = min(4, host.cpus)
        memoryGB = host.machineDefaultMemoryGB
        self.existingNames = existingNames
    }

    public var nameError: String? {
        if let error = MachineNameRule.validate(name) { return error }
        if existingNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "A machine named “\(name)” already exists."
        }
        return nil
    }

    public var imageReference: String { image.trimmingCharacters(in: .whitespaces) }

    /// Whether the image is one we know doesn't boot (create is blocked; the sheet offers the verified image).
    public var imageIsKnownBroken: Bool { MachineImageOption.knownBroken(imageReference) }

    public var imageError: String? {
        if imageReference.isEmpty { return "Choose an image." }
        if imageIsKnownBroken {
            return "Docker Hub's alpine doesn't boot as a machine: its busybox init needs OpenRC and reboots at once."
        }
        return ResourceValidator.imageReference(imageReference)
    }

    public var kernelError: String? {
        virtualization && kernelPath.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Nested virtualization needs a kernel built with CONFIG_KVM=y." : nil
    }

    public var isValid: Bool { nameError == nil && imageError == nil && kernelError == nil }

    public var spec: MachineSpec {
        var s = MachineSpec(image: imageReference, name: name)
        s.cpus = cpus
        s.memory = MemorySize(bytes: Int64(memoryGB) << 30)
        s.homeMount = homeMount.rawValue
        s.setDefault = setDefault
        s.noBoot = !bootNow
        if virtualization {
            s.virtualization = true
            let k = kernelPath.trimmingCharacters(in: .whitespaces)
            s.kernel = k.isEmpty ? nil : k
        }
        return s
    }

    public func previewCommand(executable: String = "container") -> String {
        CommandLine(executable: executable, arguments: ["machine", "create"] + spec.cliArguments).display
    }
}

/// `container machine set` keys for a resize; applied on the next boot.
public enum MachineResize {
    public static func settings(cpus: Int, memoryGB: Int) -> [String: String] {
        ["cpus": String(cpus), "memory": MemorySize(bytes: Int64(memoryGB) << 30).cliArgument]
    }

    /// The command for `settings`, in the same key order `CLIBackend.configureMachine` sends (sorted).
    public static func previewCommand(
        name: String, settings: [String: String], executable: String = "container"
    ) -> String {
        let pairs = settings.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return CommandLine(executable: executable, arguments: ["machine", "set", "-n", name] + pairs).display
    }
}

// MARK: - Kubernetes

/// State of the "Create cluster" sheet.
public struct ClusterForm: Hashable, Sendable {
    public static let defaultNodeImage = "docker.io/kindest/node:v1.35.5"

    public var name = "k8s-dev"
    public var cpus: Int
    public var memoryGB: Int
    public var nodeImage = ClusterForm.defaultNodeImage
    public var cniManifestPath = ""
    public var removeOnStop = false

    public init(host: HostResources = .current) {
        cpus = host.clusterDefaultCPUs
        memoryGB = host.clusterDefaultMemoryGB
    }

    public var nameError: String? { MachineNameRule.validate(name) }
    public var isValid: Bool { nameError == nil && !nodeImage.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Workers are never sent: CLI 1.5.0 has no `--workers`.
    public var spec: ClusterSpec {
        var s = ClusterSpec(name: name)
        s.cpus = cpus
        s.memory = MemorySize(bytes: Int64(memoryGB) << 30)
        let image = nodeImage.trimmingCharacters(in: .whitespaces)
        s.nodeImage = image == Self.defaultNodeImage ? nil : image
        s.cniManifest = cniManifestPath.isEmpty ? nil : cniManifestPath
        s.removeOnStop = removeOnStop
        return s
    }

    public func previewCommand(executable: String = "container") -> String {
        CommandLine(executable: executable, arguments: ["k8s", "create"] + spec.cliArguments).display
    }
}

/// Copyable kubectl one-liners for a cluster context.
public enum KubectlCommands {
    public static func context(_ cluster: String) -> String { "kubectl --context \(cluster)" }
    public static func quick(_ cluster: String) -> [(title: String, command: String)] {
        let k = context(cluster)
        return [
            ("List nodes", "\(k) get nodes -o wide"),
            ("All pods", "\(k) get pods -A"),
            ("Apply a manifest", "\(k) apply -f deploy.yaml"),
            ("Load a local image", "container k8s load-image --name \(cluster) IMAGE"),
            ("Delete the cluster", "container k8s delete --name \(cluster)"),
        ]
    }
}

// MARK: - Registries

/// Registry presets for the login sheet.
public enum RegistryPreset: String, CaseIterable, Identifiable, Sendable {
    case dockerHub, ghcr, custom
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dockerHub: return "Docker Hub"
        case .ghcr: return "GitHub (GHCR)"
        case .custom: return "Custom"
        }
    }

    public var server: String? {
        switch self {
        case .dockerHub: return "docker.io"
        case .ghcr: return "ghcr.io"
        case .custom: return nil
        }
    }

    public var hint: String {
        switch self {
        case .dockerHub:
            return "Use an access token, not your password (Docker Hub → Account settings → Personal access tokens)."
        case .ghcr:
            return "Use a personal access token (classic) with the write:packages scope (read:packages to pull only)."
        case .custom: return "Credentials are stored in your macOS Keychain by the container CLI."
        }
    }

    /// Plain-HTTP registries are only offered for custom (local/insecure) servers.
    public var allowsHTTP: Bool { self == .custom }

    public static func matching(server: String) -> RegistryPreset {
        let s = RegistryServerRule.normalize(server)
        return allCases.first { $0.server == s } ?? .custom
    }
}

/// Validates the server field: a host (optionally `:port`), no scheme, no spaces.
public enum RegistryServerRule {
    public static func normalize(_ server: String) -> String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public static func validate(_ server: String) -> String? {
        let s = normalize(server)
        if s.isEmpty { return "Enter a registry server." }
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            return "Leave out http:// or https:// — pick the scheme below."
        }
        if s.contains(where: \.isWhitespace) { return "Server names can't contain spaces." }
        guard s.wholeMatch(of: /[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?(\/[a-z0-9._\/-]+)?/) != nil else {
            return "Use a host name like registry.example.com or localhost:5000."
        }
        return nil
    }
}
