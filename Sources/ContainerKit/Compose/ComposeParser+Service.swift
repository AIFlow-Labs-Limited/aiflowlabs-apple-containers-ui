import Foundation

extension ComposeDecoder {
    /// Why each well-known unsupported service key is ignored. Anything else gets a generic message.
    static let unsupportedServiceKeys: [String: String] = [
        "healthcheck":
            "Health checks are not run: nothing reports the container's health, and services that wait for "
            + "`service_healthy` start right after this one.",
        "secrets": "Secrets are not supported; the container starts without them.",
        "configs": "Configs are not supported; the container starts without them.",
        "extends": "`extends` is not resolved: settings inherited from the other service are missing.",
        "links": "Links are not supported. Other services are reached by their container name instead.",
        "external_links": "External links are not supported.",
        "extra_hosts": "Extra /etc/hosts entries cannot be set with this runtime.",
        "hostname": "A custom hostname cannot be set; the hostname is always the container name.",
        "domainname": "A custom domain name cannot be set.",
        "devices": "Host devices cannot be passed to a container.",
        "gpus": "GPUs cannot be passed to a container.",
        "runtime": "Alternative runtimes are not supported.",
        "pid": "Sharing the host's or another container's PID namespace is not supported.",
        "ipc": "Sharing an IPC namespace is not supported.",
        "security_opt": "Security options are not supported.",
        "sysctls": "Kernel parameters (sysctls) cannot be set per container.",
        "logging": "Logging drivers are not supported; logs are read with `container logs`.",
        "stop_signal": "A custom stop signal is not stored with the container.",
        "stop_grace_period": "A custom stop timeout is not stored with the container.",
        "volumes_from": "`volumes_from` is not supported; list the volumes on this service.",
        "group_add": "Additional groups are not supported.",
        "pull_policy": "Pull policy is ignored: an image is pulled only when it is not available locally.",
        "scale": "Only one container per service is started.",
        "develop": "Compose Watch (`develop`) is not supported.",
    ]

    mutating func service(name: String, body: [ComposeValue.Entry]) -> ComposeService {
        var reader = ComposeMapReader(body)
        var service = ComposeService(name: name)
        let scope = ComposeWarning.Scope.service(name)

        service.image = reader.take("image")?.string
        if let build = reader.take("build") { service.build = self.build(build, scope: scope) }
        service.containerName = reader.take("container_name")?.string
        service.command = reader.take("command").flatMap { command($0, key: "command", scope: scope) }
        service.entrypoint = reader.take("entrypoint").flatMap { command($0, key: "entrypoint", scope: scope) }
        if let value = reader.take("environment") {
            if let entries = value.keyValueEntries {
                service.environment = entries
            } else {
                unreadable(scope, "environment")
            }
        }
        if let value = reader.take("env_file") { service.envFiles = envFiles(value, scope: scope) }
        if let value = reader.take("ports") { service.ports = ports(value, scope: scope) }
        if let value = reader.take("volumes") { service.mounts = mounts(value, scope: scope) }
        for path in reader.take("tmpfs")?.stringList ?? [] {
            service.mounts.append(ComposeMount(source: .tmpfs(size: nil), target: path))
        }
        if let value = reader.take("networks") { service.networks = networks(value, scope: scope) }
        if let value = reader.take("depends_on") { service.dependsOn = dependencies(value, scope: scope) }
        service.workingDirectory = reader.take("working_dir")?.string
        service.user = reader.take("user")?.string
        service.labels = reader.take("labels")?.stringMap ?? [:]
        let cpuCount = reader.take("cpu_count")?.double
        service.cpus = reader.take("cpus")?.double ?? cpuCount
        service.memory = memory(reader.take("mem_limit"), key: "mem_limit", scope: scope)
        service.platform = reader.take("platform")?.string
        service.useInit = reader.take("init")?.bool ?? false
        service.readOnly = reader.take("read_only")?.bool ?? false
        service.tty = reader.take("tty")?.bool ?? false
        service.stdinOpen = reader.take("stdin_open")?.bool ?? false
        service.dns = reader.take("dns")?.stringList ?? []
        service.dnsSearch = reader.take("dns_search")?.stringList ?? []
        service.dnsOptions = reader.take("dns_opt")?.stringList ?? []
        service.capAdd = reader.take("cap_add")?.stringList ?? []
        service.capDrop = reader.take("cap_drop")?.stringList ?? []
        service.shmSize = memory(reader.take("shm_size"), key: "shm_size", scope: scope)
        if let value = reader.take("ulimits") { service.ulimits = ulimits(value, scope: scope) }
        service.macAddress = reader.take("mac_address")?.string
        service.profiles = reader.take("profiles")?.stringList ?? []
        if let value = reader.take("deploy") { deploy(value, into: &service, scope: scope) }

        // Read and deliberately ignored without a warning: they change nothing here.
        _ = reader.take("expose")  // every container port is already reachable on the container's own IP
        _ = reader.take("attach")
        _ = reader.take("annotations")

        if let restart = reader.take("restart")?.string, restart != "no" {
            warn(
                scope, "restart",
                "Restart policy “\(restart)” is ignored: the runtime has no restart policies, so the container "
                    + "stays stopped when it exits and after a reboot.")
        }
        if reader.take("privileged")?.bool == true {
            warn(
                scope, "privileged",
                "Privileged mode does not exist in this runtime. Add the capabilities you need with `cap_add`.")
        }
        if let mode = reader.take("network_mode")?.string {
            warn(
                scope, "network_mode",
                mode == "host"
                    ? "Host networking is not available: every container runs in its own VM with its own IP "
                        + "address. Publish the ports you need instead."
                    : "Network mode “\(mode)” is not supported; the container joins the normal network.")
        }
        for key in reader.unhandledKeys {
            warn(scope, key, Self.unsupportedServiceKeys[key] ?? "`\(key)` is not supported and is ignored.")
        }
        return service
    }

    // MARK: Pieces

    private mutating func command(_ value: ComposeValue, key: String, scope: ComposeWarning.Scope) -> ComposeCommand? {
        if let text = value.string { return .shell(text) }
        if let items = value.listValue { return .exec(items.compactMap(\.string)) }
        unreadable(scope, key)
        return nil
    }

    private mutating func memory(_ value: ComposeValue?, key: String, scope: ComposeWarning.Scope) -> MemorySize? {
        guard let value else { return nil }
        guard let text = value.string, let size = MemorySize(parsing: text) else {
            unreadable(scope, key)
            return nil
        }
        return size
    }

    private mutating func envFiles(_ value: ComposeValue, scope: ComposeWarning.Scope) -> [ComposeEnvFile] {
        if let path = value.string { return [ComposeEnvFile(path: path)] }
        guard let items = value.listValue else {
            unreadable(scope, "env_file")
            return []
        }
        return items.compactMap { item in
            if let path = item.string { return ComposeEnvFile(path: path) }
            guard let entries = item.mapValue,
                let path = entries.first(where: { $0.key == "path" })?.value.string
            else { return nil }
            let required = entries.first { $0.key == "required" }?.value.bool ?? true
            return ComposeEnvFile(path: path, isRequired: required)
        }
    }

    private mutating func networks(_ value: ComposeValue, scope: ComposeWarning.Scope) -> [String] {
        if let names = value.listValue { return names.compactMap(\.string) }
        guard let entries = value.mapValue else {
            unreadable(scope, "networks")
            return []
        }
        for entry in entries {
            guard let options = entry.value.mapValue else { continue }
            for option in options where !option.value.isNull {
                switch option.key {
                case "aliases":
                    warn(
                        scope, "networks.\(entry.key).aliases",
                        "Network aliases are not set: the container is only reachable by its container name.")
                case "ipv4_address", "ipv6_address":
                    warn(
                        scope, "networks.\(entry.key).\(option.key)",
                        "A fixed IP address cannot be requested; the runtime assigns one.")
                default:
                    warn(
                        scope, "networks.\(entry.key).\(option.key)",
                        "`\(option.key)` is not supported and is ignored.")
                }
            }
        }
        return entries.map(\.key)
    }

    private mutating func dependencies(_ value: ComposeValue, scope: ComposeWarning.Scope) -> [ComposeDependency] {
        if let names = value.listValue { return names.compactMap(\.string).map { ComposeDependency(service: $0) } }
        guard let entries = value.mapValue else {
            unreadable(scope, "depends_on")
            return []
        }
        return entries.map { entry in
            let condition =
                entry.value.mapValue?.first { $0.key == "condition" }?.value.string ?? ComposeDependency.started
            if condition != ComposeDependency.started {
                warn(
                    scope, "depends_on.\(entry.key).condition",
                    "`\(condition)` is not waited for: “\(entry.key)” is started first, and this service starts "
                        + "as soon as that container is running.", severity: .note)
            }
            return ComposeDependency(service: entry.key, condition: condition)
        }
    }

    /// `{nofile: 65536}` or `{nofile: {soft: 1024, hard: 2048}}` → `nofile=65536`, `nofile=1024:2048`.
    private mutating func ulimits(_ value: ComposeValue, scope: ComposeWarning.Scope) -> [String] {
        guard let entries = value.mapValue else {
            unreadable(scope, "ulimits")
            return []
        }
        return entries.compactMap { entry in
            if let single = entry.value.int { return "\(entry.key)=\(single)" }
            let limits = entry.value.mapValue ?? []
            guard let soft = limits.first(where: { $0.key == "soft" })?.value.int else {
                unreadable(scope, "ulimits.\(entry.key)")
                return nil
            }
            let hard = limits.first { $0.key == "hard" }?.value.int
            return hard.map { "\(entry.key)=\(soft):\($0)" } ?? "\(entry.key)=\(soft)"
        }
    }

    private mutating func build(_ value: ComposeValue, scope: ComposeWarning.Scope) -> ComposeBuild? {
        if let context = value.string { return ComposeBuild(context: context) }
        guard let entries = value.mapValue else {
            unreadable(scope, "build")
            return nil
        }
        var reader = ComposeMapReader(entries)
        var build = ComposeBuild(context: reader.take("context")?.string ?? ".")
        build.dockerfile = reader.take("dockerfile")?.string
        build.args = reader.take("args")?.keyValueEntries ?? []
        build.target = reader.take("target")?.string
        build.labels = reader.take("labels")?.keyValueEntries ?? []
        build.platforms = reader.take("platforms")?.stringList ?? []
        build.noCache = reader.take("no_cache")?.bool ?? false
        build.pull = reader.take("pull")?.bool ?? false
        for key in reader.unhandledKeys {
            warn(scope, "build.\(key)", "Build option `\(key)` is not supported and is ignored.")
        }
        return build
    }

    /// `deploy:` — only `resources.limits.cpus` / `.memory` map onto anything.
    private mutating func deploy(_ value: ComposeValue, into service: inout ComposeService, scope: ComposeWarning.Scope)
    {
        guard let entries = value.mapValue else { return }
        var reader = ComposeMapReader(entries)
        if let resources = reader.take("resources")?.mapValue {
            var resourceReader = ComposeMapReader(resources)
            if let limits = resourceReader.take("limits")?.mapValue {
                var limitReader = ComposeMapReader(limits)
                if let cpus = limitReader.take("cpus")?.double { service.cpus = service.cpus ?? cpus }
                if let memory = memory(limitReader.take("memory"), key: "deploy.resources.limits.memory", scope: scope)
                {
                    service.memory = service.memory ?? memory
                }
                for key in limitReader.unhandledKeys {
                    warn(scope, "deploy.resources.limits.\(key)", "This limit is not supported and is ignored.")
                }
            }
            if resourceReader.has("reservations") {
                warn(
                    scope, "deploy.resources.reservations",
                    "Resource reservations (including GPU devices) are not supported and are ignored.")
            }
            for key in resourceReader.unhandledKeys {
                warn(scope, "deploy.resources.\(key)", "`\(key)` is not supported and is ignored.")
            }
        }
        if let replicas = reader.take("replicas")?.int, replicas != 1 {
            warn(scope, "deploy.replicas", "Only one container per service is started (the file asks for \(replicas)).")
        }
        for key in reader.unhandledKeys {
            warn(
                scope, "deploy.\(key)",
                "`deploy.\(key)` is a Swarm/orchestrator setting; it is not supported and is ignored.")
        }
    }
}
