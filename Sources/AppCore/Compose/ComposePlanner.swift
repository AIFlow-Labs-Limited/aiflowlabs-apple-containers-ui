import ContainerKit
import Foundation

/// A parsed compose file plus where it lives (relative paths resolve against `directory`).
public struct ComposeProject: Hashable, Sendable {
    public var file: ComposeFile
    /// Absolute path of the folder that contains the compose file.
    public var directory: String

    /// `file` as found in `directory`.
    public init(file: ComposeFile, directory: String) {
        self.file = file
        self.directory = directory
    }
}

/// Turns a compose file into a `ComposePlan`. Pure: everything it needs to know about the engine comes in
/// through `ComposeEnvironment`, so the same inputs always give the same plan.
public enum ComposePlanner {
    /// Labels Docker Compose puts on what it creates; set as well so other tools recognise the stack.
    public enum DockerLabel {
        public static let project = "com.docker.compose.project"
        public static let service = "com.docker.compose.service"
        public static let network = "com.docker.compose.network"
        public static let volume = "com.docker.compose.volume"
    }

    /// Project name when the file has no `name:`: the folder name, made safe.
    public static func defaultProjectName(for project: ComposeProject) -> String {
        if let name = project.file.name, !name.isEmpty { return name }
        return normalizedProjectName((project.directory as NSString).lastPathComponent)
    }

    /// Docker Compose's rule: lowercase letters, digits, `-` and `_`, starting with a letter or digit.
    public static func normalizedProjectName(_ raw: String) -> String {
        let cleaned = raw.lowercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
        let trimmed = cleaned.drop { $0 == "-" || $0 == "_" }
        return trimmed.isEmpty ? "compose" : String(trimmed)
    }

    /// Builds the plan for `project` with `options`, checked against what `environment` says already exists.
    ///
    /// - Parameters:
    ///   - home: home folder for `~` in host paths.
    ///   - pathExists: file-system probe for bind-mount sources and env files (injected for tests).
    ///   - readFile: text of an env file, `nil` when it cannot be read as UTF-8 (injected for tests).
    public static func plan(
        _ project: ComposeProject, options: ComposeOptions = ComposeOptions(),
        environment: ComposeEnvironment = ComposeEnvironment(), home: String = NSHomeDirectory(),
        pathExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        readFile: @escaping (String) -> String? = { path in
            FileManager.default.contents(atPath: path).flatMap { String(data: $0, encoding: .utf8) }
        }
    ) -> ComposePlan {
        var builder = ComposePlanBuilder(
            project: project, options: options, environment: environment, home: home, pathExists: pathExists,
            readFile: readFile)
        return builder.build()
    }

    /// Services in start order (dependencies first, otherwise file order), or the cycle that makes that
    /// impossible (`["a", "b", "a"]`). Dependencies on services outside `services` are ignored here.
    public static func startOrder(_ services: [ComposeService]) -> (order: [ComposeService], cycle: [String]?) {
        let byName = Dictionary(services.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var done = Set<String>()
        var path: [String] = []
        var order: [ComposeService] = []
        var cycle: [String]?

        func visit(_ service: ComposeService) {
            guard cycle == nil, !done.contains(service.name) else { return }
            if let start = path.firstIndex(of: service.name) {
                cycle = Array(path[start...]) + [service.name]
                return
            }
            path.append(service.name)
            for dependency in service.dependsOn {
                if let next = byName[dependency.service] { visit(next) }
            }
            path.removeLast()
            guard cycle == nil else { return }
            done.insert(service.name)
            order.append(service)
        }
        for service in services { visit(service) }
        return (cycle == nil ? order : [], cycle)
    }
}

/// Working state of one planning run.
struct ComposePlanBuilder {
    let project: ComposeProject
    let options: ComposeOptions
    let environment: ComposeEnvironment
    let home: String
    let pathExists: (String) -> Bool
    let readFile: (String) -> String?
    var plan: ComposePlan
    /// Compose volume key → real volume name.
    var volumeNames: [String: String] = [:]
    /// Compose network key → real network name (`asDeclared` only).
    var networkNames: [String: String] = [:]

    var file: ComposeFile { project.file }
    var projectName: String { plan.projectName }

    init(
        project: ComposeProject, options: ComposeOptions, environment: ComposeEnvironment, home: String,
        pathExists: @escaping (String) -> Bool, readFile: @escaping (String) -> String?
    ) {
        self.project = project
        self.options = options
        self.environment = environment
        self.home = home
        self.pathExists = pathExists
        self.readFile = readFile
        let name = options.projectName?.trimmingCharacters(in: .whitespaces) ?? ""
        plan = ComposePlan(projectName: name.isEmpty ? ComposePlanner.defaultProjectName(for: project) : name)
    }

    mutating func note(_ scope: ComposeWarning.Scope, _ key: String, _ message: String) {
        let warning = ComposeWarning(scope: scope, key: key, message: message, severity: .note)
        if !plan.warnings.contains(warning) { plan.warnings.append(warning) }
    }

    mutating func problem(_ message: String, service: String? = nil, kind: ComposeProblem.Kind = .other) {
        let problem = ComposeProblem(message, service: service, kind: kind)
        if !plan.problems.contains(problem) { plan.problems.append(problem) }
    }

    func isEnabled(_ service: ComposeService) -> Bool {
        service.profiles.isEmpty || !options.enabledProfiles.isDisjoint(with: service.profiles)
    }

    func containerName(for service: ComposeService) -> String {
        if let explicit = service.containerName, !explicit.isEmpty { return explicit }
        return options.naming == .serviceName ? service.name : "\(projectName)-\(service.name)"
    }

    func imageName(for service: ComposeService) -> String {
        if let image = service.image, !image.isEmpty { return image }
        return service.build == nil ? "" : "\(projectName)-\(service.name):latest"
    }

    /// Labels that make the Containers list group the stack and other tools recognise it.
    func projectLabels(_ extra: [String: String] = [:]) -> [String: String] {
        var labels = extra
        labels[AppLabel.project] = projectName
        labels[ComposePlanner.DockerLabel.project] = projectName
        return labels
    }

    // MARK: Build

    mutating func build() -> ComposePlan {
        plan.warnings = file.warnings
        if ResourceValidator.resourceName(projectName, allowDots: false) != nil {
            problem(
                "“\(projectName)” is not a usable project name: use letters, digits, “-” or “_”, starting with a "
                    + "letter or digit.")
        }
        for name in file.unsetVariables {
            note(.file, "variables", "The variable \(name) has no value and no default; it is replaced by nothing.")
        }

        let selected = file.services.filter(isEnabled)
        if selected.isEmpty {
            problem("No service is selected: every service belongs to a profile that is switched off.")
        }
        checkDependencies(selected)
        let (ordered, cycle) = ComposePlanner.startOrder(selected)
        if let cycle {
            problem("Services depend on each other in a circle: \(cycle.joined(separator: " → ")).")
        }

        planNetworks(selected)
        planVolumes(selected)
        planImages(selected)
        planContainers(cycle == nil ? ordered : selected)
        describeNaming()
        plan.services = file.services.map(summary)
        return plan
    }

    private mutating func checkDependencies(_ selected: [ComposeService]) {
        let selectedNames = Set(selected.map(\.name))
        for service in selected {
            for dependency in service.dependsOn where !selectedNames.contains(dependency.service) {
                if let other = file.service(named: dependency.service) {
                    problem(
                        "“\(service.name)” depends on “\(other.name)”, which is switched off (profile "
                            + "\(other.profiles.joined(separator: ", "))). Enable that profile.",
                        service: service.name)
                } else {
                    problem(
                        "“\(service.name)” depends on “\(dependency.service)”, which is not a service in this file.",
                        service: service.name)
                }
            }
        }
    }

    private mutating func planNetworks(_ selected: [ComposeService]) {
        let usesNetworks = !file.networks.isEmpty || selected.contains { !$0.networks.isEmpty }
        guard options.networking == .asDeclared else {
            if usesNetworks {
                note(
                    .file, "networks",
                    "The networks in this file are not created. Every container joins the runtime's built-in "
                        + "`default` network, the only one where containers can find each other by name on "
                        + "CLI 1.5.0. Choose “Networks from the file” if you need the isolation instead.")
            }
            return
        }
        var keys: [String] = []
        for service in selected {
            for key in service.networks.isEmpty ? ["default"] : service.networks where !keys.contains(key) {
                keys.append(key)
            }
        }
        for key in keys {
            let declared = file.networks.first { $0.key == key }
            // An external resource without `name:` is looked up under its key, not the project prefix.
            let name = declared?.name ?? (declared?.isExternal == true ? key : "\(projectName)_\(key)")
            networkNames[key] = name
            if declared == nil, key != "default" {
                note(
                    .network(key), "networks",
                    "“\(key)” is used by a service but not declared under top-level `networks:`; it is created "
                        + "as \(name).")
            }
            if environment.networks.contains(name) {
                plan.reused.append("network \(name)")
            } else if declared?.isExternal == true {
                problem(
                    "Network “\(name)” is marked `external`, so it must already exist, and it does not. "
                        + "Create it under Networks first.")
            } else {
                var labels = projectLabels(declared?.labels ?? [:])
                labels[ComposePlanner.DockerLabel.network] = key
                plan.steps.append(
                    ComposeStep(
                        id: "network:\(name)",
                        action: .createNetwork(
                            name: name, subnet: declared?.subnet, subnetV6: declared?.subnetV6, labels: labels)))
            }
        }
    }

    private mutating func planVolumes(_ selected: [ComposeService]) {
        var keys: [String] = []
        for service in selected {
            for mount in service.mounts {
                if case .volume(let key) = mount.source, !keys.contains(key) { keys.append(key) }
            }
        }
        for key in keys {
            let declared = file.volumes.first { $0.key == key }
            // An external resource without `name:` is looked up under its key, not the project prefix.
            let name = declared?.name ?? (declared?.isExternal == true ? key : "\(projectName)_\(key)")
            volumeNames[key] = name
            if declared == nil {
                note(
                    .volume(key), "volumes",
                    "“\(key)” is used by a service but not declared under top-level `volumes:`; it is created "
                        + "as \(name).")
            }
            if environment.volumes.contains(name) {
                plan.reused.append("volume \(name)")
            } else if declared?.isExternal == true {
                problem(
                    "Volume “\(name)” is marked `external`, so it must already exist, and it does not. "
                        + "Create it under Volumes first.")
            } else {
                var labels = projectLabels(declared?.labels ?? [:])
                labels[ComposePlanner.DockerLabel.volume] = key
                plan.steps.append(ComposeStep(id: "volume:\(name)", action: .createVolume(name: name, labels: labels)))
            }
        }
    }

    private mutating func planImages(_ selected: [ComposeService]) {
        var queued = Set<String>()
        for service in selected {
            let image = imageName(for: service)
            if let build = service.build {
                plan.steps.append(
                    ComposeStep(
                        id: "build:\(service.name)", action: .buildImage(buildSpec(build, tag: image)),
                        service: service.name))
            } else if image.isEmpty {
                problem("“\(service.name)” has neither `image:` nor `build:`.", service: service.name)
            } else {
                let canonical = ImageReferenceName.canonical(image)
                guard !environment.images.contains(canonical), queued.insert(canonical).inserted else { continue }
                plan.steps.append(
                    ComposeStep(
                        id: "pull:\(image)",
                        action: .pullImage(reference: image, platform: platform(for: service)), service: service.name))
            }
        }
    }

    private mutating func planContainers(_ ordered: [ComposeService]) {
        var names: [String: String] = [:]  // container name → service
        var hostPorts: [String: String] = [:]  // "8080/tcp" → service
        for service in ordered {
            let name = containerName(for: service)
            if !RunSpec.isValidName(name) {
                problem(
                    "“\(name)” is not a valid container name: use letters, digits, “.”, “_” or “-”, starting with "
                        + "a letter or digit.", service: service.name)
            }
            if let other = names[name] {
                problem("“\(service.name)” and “\(other)” would both be named “\(name)”.", service: service.name)
                continue
            }
            names[name] = service.name
            if let existing = environment.containers[name] {
                if options.replaceExisting.contains(name) {
                    plan.steps.append(
                        ComposeStep(id: "remove:\(name)", action: .removeContainer(name: name), service: service.name))
                } else {
                    problem(
                        "A container named “\(name)” already exists\(existing.isRunning ? " and is running" : ""). "
                            + "Replace it, delete it yourself, or change the naming.",
                        service: service.name, kind: .containerExists(name: name))
                }
            }
            let spec = runSpec(for: service, name: name)
            for port in spec.ports {
                let slot = "\(port.hostPort)/\(port.proto)"
                if let other = hostPorts[slot], other != service.name {
                    problem(
                        "Host port \(port.hostPort) is published by both “\(other)” and “\(service.name)”.",
                        service: service.name)
                }
                hostPorts[slot] = service.name
                let holder = environment.containers.first {
                    $0.key != name && $0.value.isRunning && $0.value.hostPorts.contains(slot)
                }
                if let holder {
                    note(
                        .service(service.name), "ports",
                        "Host port \(port.hostPort) is already published by the running container “\(holder.key)”; "
                            + "starting this one will probably fail until that container is stopped.")
                }
            }
            plan.steps.append(ComposeStep(id: "run:\(name)", action: .runContainer(spec), service: service.name))
        }
    }

    // MARK: Names

    /// Names other containers can use for `containerName`, as far as CLI 1.5.0 is known to resolve them.
    func hostnames(for containerName: String) -> [String] {
        guard options.networking == .sharedDefault, let domain = environment.dnsDomain else { return [] }
        return containerName.contains(".") ? [containerName] : [containerName, "\(containerName).\(domain)"]
    }

    private mutating func describeNaming() {
        let example = plan.containerNames.first ?? "db"
        switch (options.networking, environment.dnsDomain) {
        case (.asDeclared, _):
            plan.namingSummary =
                "Containers join the networks from the file. On CLI 1.5.0, name lookup only works on the built-in "
                + "`default` network (apple/container#1809), so on these networks services reach each other by IP "
                + "address only; names such as “\(example)” do not resolve."
            note(.file, "names", plan.namingSummary)
        case (.sharedDefault, .some(let domain)):
            plan.namingSummary =
                "All containers join the built-in `default` network. The engine's DNS domain is “\(domain)”, so "
                + "each container is reachable from the others by its container name: “\(example)” or "
                + "“\(example).\(domain)”."
        case (.sharedDefault, nil):
            if let domain = environment.unregisteredDNSDomain {
                plan.namingSummary =
                    "The engine's DNS domain is set to “\(domain)”, but that domain is not registered "
                    + "(`container system dns list` does not show it), so containers cannot find each other by name: "
                    + "“\(example)” will not resolve. Enable DNS names under Settings → Network, or connect by IP address."
            } else if environment.isLoaded {
                plan.namingSummary =
                    "No DNS domain is configured, so containers cannot find each other by name: “\(example)” will not "
                    + "resolve. Set one up under Settings → Network, or connect by IP address."
            } else {
                plan.namingSummary =
                    "The engine is not running, so its DNS setup could not be checked. Container names only resolve "
                    + "when a DNS domain is configured (Settings → Network)."
            }
            note(.file, "names", plan.namingSummary)
        }
        guard options.naming == .projectPrefixed else { return }
        let renamed = file.services.filter { isEnabled($0) && containerName(for: $0) != $0.name }
        if let first = renamed.first {
            note(
                .file, "names",
                "Containers are named after the project (“\(containerName(for: first))”), so the service names the "
                    + "file uses for its own connections (“\(first.name)”) do not resolve. Use the container names "
                    + "in your configuration, or switch naming to “Service names”.")
        }
    }

    private func summary(_ service: ComposeService) -> ComposeServiceSummary {
        let name = containerName(for: service)
        return ComposeServiceSummary(
            name: service.name, containerName: name, image: imageName(for: service), isBuilt: service.build != nil,
            isEnabled: isEnabled(service), profiles: service.profiles,
            ports: service.ports.map {
                let host = $0.hostAddress.map { "\($0):" } ?? ""
                return "\(host)\($0.published ?? $0.target)→\($0.target)\($0.proto == "tcp" ? "" : "/\($0.proto)")"
            },
            hostnames: hostnames(for: name))
    }
}
