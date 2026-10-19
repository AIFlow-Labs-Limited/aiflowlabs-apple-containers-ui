import ContainerKit
import Foundation

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
            PortMapping(
                hostAddress: $0.hostAddress == "0.0.0.0" ? nil : $0.hostAddress,
                hostPort: $0.hostPort, containerPort: $0.containerPort, proto: $0.proto)
        }
        for m in cfg.mounts {
            switch m.type {
            case .bind:
                mounts.append(MountSpec(kind: .bind(hostPath: m.source), target: m.destination, readOnly: m.isReadOnly))
            case .volume(let name, _):
                mounts.append(MountSpec(kind: .volume(name: name), target: m.destination, readOnly: m.isReadOnly))
            case .tmpfs: tmpfs.append(m.destination)
            case .other: break
            }
        }

        // Resources and platform
        cpus = cfg.resources.cpus
        memory = MemorySize(bytes: cfg.resources.memoryInBytes)
        if cfg.platform.architecture != "arm64" { platform = cfg.platform }

        // Networks: the first maps onto the modelled fields; further attachments are kept as extra `--network`.
        if let attachment = cfg.networks.first {
            if attachment.network != "default" { network = attachment.network }
            macAddress = attachment.options?.mac
            networkAliases = attachment.options?.aliases ?? []
        }
        for attachment in cfg.networks.dropFirst() {
            var spec = attachment.network
            if let mac = attachment.options?.mac { spec += ",mac=\(mac)" }
            for alias in attachment.options?.aliases ?? [] { spec += ",alias=\(alias)" }
            extraArguments += ["--network", spec]
        }
        if let domain = cfg.dns?.domain, !domain.isEmpty { dnsDomain = domain }
        // `--rm`, `--ulimit` and `--shm-size` are not reported by `container inspect` (CLI 1.5.0), so they cannot
        // be recreated here.

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

    /// `container run …` as a shell-quoted one-liner, **unmasked** (legacy; secrets verbatim). For anything shown
    /// on screen use `commandLineString()` / `commandLineString(maskSecrets: true)`.
    var commandLineString: String { commandLineString(maskSecrets: false) }

    /// `container run …` as a shell-quoted one-liner. `maskSecrets` (default) replaces sensitive environment
    /// values (`EnvironmentVariable.isSensitive`) with `KEY=…` for display.
    func commandLineString(maskSecrets: Bool = true) -> String {
        var args = cliArguments
        if maskSecrets {
            var i = 0
            while i < args.count - 1 {
                if args[i] == "-e" || args[i] == "--env" {
                    args[i + 1] = EnvironmentVariable(parsing: args[i + 1]).maskedEntry
                    i += 2
                } else {
                    i += 1
                }
            }
        }
        return ShellWords.join(["container", "run"] + args)
    }
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
    case invalidImage(String)
    case relativeMountSource(String)

    public var description: String {
        switch self {
        case .missingImage: return "Choose an image."
        case .invalidName(let n):
            return "“\(n)” is not a valid name: use letters, digits, '.', '_' or '-', starting with a letter or digit."
        case .portOutOfRange(let p): return "Port \(p) is out of range (1–65535)."
        case .duplicateHostPort(let p): return "Host port \(p) is published more than once."
        case .memoryTooSmall: return "Memory must be at least 64 MB."
        case .missingMountTarget: return "Every volume needs a container path."
        case .relativeMountTarget(let t): return "Container path “\(t)” must be absolute."
        case .invalidImage(let i):
            return "“\(i)” is not an image reference (it cannot start with “-” or contain spaces)."
        case .relativeMountSource(let p): return "Host path “\(p)” must be absolute (or start with ~)."
        }
    }
}

public extension RunSpec {
    /// Minimum memory the runtime accepts for a container VM.
    static let minimumMemoryBytes: Int64 = 64 << 20

    /// `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`
    static func isValidName(_ name: String) -> Bool {
        name == name.trimmingCharacters(in: .whitespaces) && ResourceValidator.resourceName(name, maxLength: nil) == nil
    }

    /// Validation used by the Run sheet. Empty means the spec can be submitted.
    var issues: [RunSpecIssue] {
        var result: [RunSpecIssue] = []
        let trimmedImage = image.trimmingCharacters(in: .whitespaces)
        if trimmedImage.isEmpty {
            result.append(.missingImage)
        } else if trimmedImage.hasPrefix("-") || trimmedImage.contains(where: \.isWhitespace) {
            result.append(.invalidImage(image))
        }
        if let name, !name.isEmpty, !Self.isValidName(name) { result.append(.invalidName(name)) }
        // Host addresses per (port, proto). A wildcard (`nil`, empty, `*`, `0.0.0.0`, `::`) collides with any address.
        var bound: [String: Set<String>] = [:]
        for p in ports {
            for port in [p.hostPort, p.containerPort] where !(1...65_535).contains(port) {
                result.append(.portOutOfRange(port))
            }
            let slot = "\(p.hostPort)/\(p.proto.lowercased())"
            let host = Self.normalizedHostAddress(p.hostAddress)
            let existing = bound[slot, default: []]
            let clashes = existing.contains(host) || (!existing.isEmpty && (host == "*" || existing.contains("*")))
            if clashes, !result.contains(.duplicateHostPort(p.hostPort)) {
                result.append(.duplicateHostPort(p.hostPort))
            }
            bound[slot, default: []].insert(host)
        }
        if let memory, memory.bytes < Self.minimumMemoryBytes { result.append(.memoryTooSmall(memory.bytes)) }
        for m in mounts {
            if m.target.isEmpty {
                result.append(.missingMountTarget)
            } else if !m.target.hasPrefix("/") {
                result.append(.relativeMountTarget(m.target))
            }
            if case .bind(let source) = m.kind, !source.isEmpty, !source.hasPrefix("/"), !source.hasPrefix("~") {
                result.append(.relativeMountSource(source))
            }
        }
        return result
    }

    /// `nil`, empty, `*`, `0.0.0.0`, `::`, `[::]` → `"*"`; otherwise the trimmed, lowercased address.
    static func normalizedHostAddress(_ address: String?) -> String {
        let a = (address ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        return ["", "*", "0.0.0.0", "::", "[::]"].contains(a) ? "*" : a
    }

    /// The spec as it should be handed to the CLI: `~` in bind-mount sources expanded (the CLI does not expand
    /// it), the image trimmed.
    func normalizedForRun(home: String = NSHomeDirectory()) -> RunSpec {
        var copy = self
        copy.image = image.trimmingCharacters(in: .whitespaces)
        copy.mounts = mounts.map { m in
            guard case .bind(let source) = m.kind, source.hasPrefix("~") else { return m }
            var expanded = m
            expanded.kind = .bind(hostPath: ResourceValidator.resolvedPath(source, relativeTo: nil, home: home))
            return expanded
        }
        return copy
    }
}
