import ContainerKit
import Foundation

// One compose service → one `RunSpec` (and `BuildSpec`), i.e. the same `container run` path the Run sheet uses.
extension ComposePlanBuilder {
    /// Absolute host path for a path written in the compose file (`./x`, `~/x`, `/x`).
    func resolve(_ path: String) -> String {
        ResourceValidator.resolvedPath(path, relativeTo: project.directory, home: home)
    }

    /// `linux/amd64`, `linux/arm64/v8` or a bare `amd64`.
    func platform(for service: ComposeService) -> Platform? {
        guard let text = service.platform, !text.isEmpty else { return nil }
        return Self.platform(text)
    }

    static func platform(_ text: String) -> Platform {
        let parts = text.split(separator: "/").map(String.init)
        switch parts.count {
        case 1: return Platform(architecture: parts[0])
        case 2: return Platform(architecture: parts[1], os: parts[0])
        default: return Platform(architecture: parts[1], os: parts[0], variant: parts[2])
        }
    }

    func buildSpec(_ build: ComposeBuild, tag: String) -> BuildSpec {
        let context = resolve(build.context)
        var spec = BuildSpec(contextDirectory: context, tag: tag)
        // Compose resolves `dockerfile:` against the build context, not the compose file.
        spec.dockerfile = build.dockerfile.map {
            ResourceValidator.resolvedPath($0, relativeTo: context, home: home)
        }
        spec.buildArgs = build.args
        spec.target = build.target
        spec.labels = build.labels
        spec.platforms = build.platforms.map(Self.platform)
        spec.noCache = build.noCache
        spec.pull = build.pull
        return spec
    }

    mutating func runSpec(for service: ComposeService, name: String) -> RunSpec {
        let scope = ComposeWarning.Scope.service(service.name)
        var spec = RunSpec(image: imageName(for: service))
        spec.name = name
        spec.detach = true
        spec.interactive = service.stdinOpen
        spec.tty = service.tty
        applyProcess(service, to: &spec)
        spec.environment = service.environment
        for envFile in service.envFiles {
            let path = resolve(envFile.path)
            if pathExists(path) {
                spec.envFiles.append(path)
            } else if envFile.isRequired {
                problem("The env file \(path) of “\(service.name)” does not exist.", service: service.name)
            }
        }
        for port in service.ports {
            if port.published == nil {
                note(
                    scope, "ports",
                    "Port \(port.target) has no host port. Docker would pick a random free one; here it is "
                        + "published on the same number, \(port.target).")
            }
            spec.ports.append(
                RunSpec.PortMapping(
                    hostAddress: port.hostAddress, hostPort: port.published ?? port.target, containerPort: port.target,
                    proto: port.proto))
        }
        applyMounts(service, to: &spec, scope: scope)
        spec.workingDirectory = service.workingDirectory
        spec.user = service.user
        applyResources(service, to: &spec, scope: scope)
        spec.platform = platform(for: service)
        applyNetwork(service, to: &spec)
        var labels = projectLabels(service.labels)
        labels[ComposePlanner.DockerLabel.service] = service.name
        spec.labels = labels
        spec.useInit = service.useInit
        spec.readOnly = service.readOnly
        spec.capAdd = service.capAdd
        spec.capDrop = service.capDrop
        spec.shmSize = service.shmSize
        spec.ulimits = service.ulimits
        for server in service.dns { spec.extraArguments += ["--dns", server] }
        for domain in service.dnsSearch { spec.extraArguments += ["--dns-search", domain] }
        for option in service.dnsOptions { spec.extraArguments += ["--dns-option", option] }
        return spec
    }

    /// `--entrypoint` takes one executable, so the rest of a multi-word entrypoint leads the arguments.
    private func applyProcess(_ service: ComposeService, to spec: inout RunSpec) {
        func words(_ command: ComposeCommand?) -> [String] {
            switch command {
            case .shell(let text): return ShellWords.split(text)
            case .exec(let list): return list
            case nil: return []
            }
        }
        let entrypoint = words(service.entrypoint)
        spec.entrypoint = entrypoint.first
        spec.command = Array(entrypoint.dropFirst()) + words(service.command)
    }

    private mutating func applyMounts(_ service: ComposeService, to spec: inout RunSpec, scope: ComposeWarning.Scope) {
        for mount in service.mounts {
            switch mount.source {
            case .bind(let source):
                let path = resolve(source)
                if !pathExists(path) {
                    note(
                        scope, "volumes",
                        "The host path \(path) does not exist. Docker would create it as an empty folder; this "
                            + "runtime refuses to start the container instead, so create it before running.")
                }
                spec.mounts.append(.init(kind: .bind(hostPath: path), target: mount.target, readOnly: mount.readOnly))
            case .volume(let key):
                let volume = volumeNames[key] ?? "\(projectName)_\(key)"
                spec.mounts.append(.init(kind: .volume(name: volume), target: mount.target, readOnly: mount.readOnly))
                let setsDataDirectory = service.environment.contains { $0.hasPrefix("PGDATA=") }
                if mount.target == "/var/lib/postgresql/data", !setsDataDirectory {
                    note(
                        scope, "volumes",
                        "Named volumes here are ext4 disks with a `lost+found` folder at the top, which makes "
                            + "PostgreSQL refuse to initialise in \(mount.target). If the database does not start, "
                            + "add PGDATA=/var/lib/postgresql/data/pgdata to its environment.")
                }
            case .anonymous:
                spec.mounts.append(.init(kind: .anonymous, target: mount.target, readOnly: mount.readOnly))
            case .tmpfs(let size):
                spec.tmpfs.append(size.map { "\(mount.target):size=\($0.cliArgument)" } ?? mount.target)
            }
        }
    }

    private mutating func applyResources(_ service: ComposeService, to spec: inout RunSpec, scope: ComposeWarning.Scope)
    {
        if let cpus = service.cpus, cpus > 0 {
            let whole = max(1, Int(cpus.rounded(.up)))
            if Double(whole) != cpus {
                note(
                    scope, "cpus",
                    "The runtime only takes whole CPUs: \(cpus.formatted()) is rounded up to \(whole).")
            }
            spec.cpus = whole
        }
        if let memory = service.memory {
            if memory.bytes < RunSpec.minimumMemoryBytes {
                note(scope, "mem_limit", "Memory limits below 64 MB are not accepted; 64 MB is used.")
                spec.memory = MemorySize(bytes: RunSpec.minimumMemoryBytes)
            } else {
                spec.memory = memory
            }
        }
    }

    private func applyNetwork(_ service: ComposeService, to spec: inout RunSpec) {
        spec.macAddress = service.macAddress
        guard options.networking == .asDeclared else { return }
        let keys = service.networks.isEmpty ? ["default"] : service.networks
        let names = keys.map { networkNames[$0] ?? "\(projectName)_\($0)" }
        spec.network = names.first
        for extra in names.dropFirst() { spec.extraArguments += ["--network", extra] }
    }
}
