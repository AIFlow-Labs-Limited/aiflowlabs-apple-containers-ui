import Foundation
import ContainerKit

public extension RunSpec {
    /// Rebuilds the `container run` parameters that would recreate `container` ("Copy `container run`").
    ///
    /// The CLI reports the *resolved* init process (image entrypoint + cmd already applied). When the image's
    /// runtime config is known, the image defaults are subtracted so the command stays short and re-running it
    /// does not double the entrypoint; without it the full process becomes `--entrypoint` + arguments when
    /// it is a single executable, else the command.
    init(recreating container: Container, imageConfig: Image.OCIConfig.RuntimeConfig? = nil) {
        let cfg = container.configuration
        self.init(image: cfg.image.reference)
        name = container.id

        // Process
        let process = [cfg.initProcess.executable] + cfg.initProcess.arguments
        if let imageConfig {
            let entry = imageConfig.entrypoint ?? []
            let defaults = entry + (imageConfig.cmd ?? [])
            if process == defaults {
                command = []
            } else if !entry.isEmpty, process.starts(with: entry) {
                command = Array(process.dropFirst(entry.count))
            } else if !entry.isEmpty {
                entrypoint = cfg.initProcess.executable
                command = cfg.initProcess.arguments
            } else {
                command = process
            }
        } else {
            command = process
        }

        // Environment minus what the image already sets.
        let imageEnv = Set(imageConfig?.env ?? [])
        environment = cfg.initProcess.environment.filter { !imageEnv.contains($0) }
        let imageDir = imageConfig?.workingDir.flatMap { $0.isEmpty ? nil : $0 } ?? "/"
        if let dir = cfg.initProcess.workingDirectory, !dir.isEmpty, dir != imageDir { workingDirectory = dir }
        if let user = cfg.initProcess.user {
            let display = user.display
            let imageUser = imageConfig?.user ?? ""
            if display != "0:0", display != "root", display != imageUser { self.user = display }
        }

        // Ports, mounts
        ports = cfg.publishedPorts.map {
            PortMapping(hostAddress: $0.hostAddress == "0.0.0.0" ? nil : $0.hostAddress,
                        hostPort: $0.hostPort, containerPort: $0.containerPort, proto: $0.proto)
        }
        for m in cfg.mounts {
            switch m.type {
            case .bind: mounts.append(MountSpec(kind: .bind(hostPath: m.source), target: m.destination, readOnly: m.isReadOnly))
            case .volume(let name, _): mounts.append(MountSpec(kind: .volume(name: name), target: m.destination, readOnly: m.isReadOnly))
            case .tmpfs: tmpfs.append(m.destination)
            case .other: break
            }
        }

        // Resources and platform
        cpus = cfg.resources.cpus
        memory = MemorySize(bytes: cfg.resources.memoryInBytes)
        if cfg.platform.architecture != "arm64" { platform = cfg.platform }

        // Network
        if let attachment = cfg.networks.first {
            if attachment.network != "default" { network = attachment.network }
            macAddress = attachment.options?.mac
            networkAliases = attachment.options?.aliases ?? []
        }

        // Labels the user set (runtime-owned `com.apple.container.*` labels are dropped).
        labels = cfg.labels.filter { !$0.key.hasPrefix("com.apple.container.") }
        useInit = cfg.useInit
        readOnly = cfg.readOnly
        rosetta = cfg.rosetta
        ssh = cfg.ssh
        virtualization = cfg.virtualization
        capAdd = cfg.capAdd
        capDrop = cfg.capDrop
    }

    /// `container run …` as a shell-quoted one-liner.
    var commandLineString: String { ShellWords.join(["container", "run"] + cliArguments) }
}

/// Problems the Run sheet shows inline before enabling Run.
public enum RunSpecIssue: Hashable, Sendable, CustomStringConvertible {
    case missingImage
    case invalidName(String)
    case portOutOfRange(Int)
    case duplicateHostPort(Int)
    case memoryTooSmall(Int64)
    case missingMountTarget
    case relativeMountTarget(String)

    public var description: String {
        switch self {
        case .missingImage: return "Choose an image."
        case .invalidName(let n): return "“\(n)” is not a valid name: use letters, digits, '.', '_' or '-', starting with a letter or digit."
        case .portOutOfRange(let p): return "Port \(p) is out of range (1–65535)."
        case .duplicateHostPort(let p): return "Host port \(p) is published more than once."
        case .memoryTooSmall: return "Memory must be at least 64 MB."
        case .missingMountTarget: return "Every volume needs a container path."
        case .relativeMountTarget(let t): return "Container path “\(t)” must be absolute."
        }
    }
}

public extension RunSpec {
    /// Minimum memory the runtime accepts for a container VM.
    static let minimumMemoryBytes: Int64 = 64 << 20

    /// `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`
    static func isValidName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-zA-Z0-9][a-zA-Z0-9_.\-]*/) != nil
    }

    /// Validation used by the Run sheet. Empty means the spec can be submitted.
    var issues: [RunSpecIssue] {
        var result: [RunSpecIssue] = []
        if image.trimmingCharacters(in: .whitespaces).isEmpty { result.append(.missingImage) }
        if let name, !name.isEmpty, !Self.isValidName(name) { result.append(.invalidName(name)) }
        var seen = Set<String>()
        for p in ports {
            for port in [p.hostPort, p.containerPort] where !(1...65_535).contains(port) {
                result.append(.portOutOfRange(port))
            }
            let key = "\(p.hostAddress ?? "*")|\(p.hostPort)|\(p.proto)"
            if !seen.insert(key).inserted, !result.contains(.duplicateHostPort(p.hostPort)) {
                result.append(.duplicateHostPort(p.hostPort))
            }
        }
        if let memory, memory.bytes < Self.minimumMemoryBytes { result.append(.memoryTooSmall(memory.bytes)) }
        for m in mounts {
            if m.target.isEmpty { result.append(.missingMountTarget) } else if !m.target.hasPrefix("/") {
                result.append(.relativeMountTarget(m.target))
            }
        }
        return result
    }
}
