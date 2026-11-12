import ContainerKit
import Foundation

/// Choices the import preview offers on top of the compose file.
public struct ComposeOptions: Hashable, Sendable {
    /// How containers are named, which is also the hostname other containers reach them by.
    public enum Naming: String, Hashable, Sendable, CaseIterable {
        /// The service name (`db`), so references between services in the file keep working. Names are global,
        /// so two projects with a `db` service collide.
        case serviceName
        /// `<project>-<service>` (`shop-db`): never collides across projects, but the file's own references to
        /// `db` no longer resolve.
        case projectPrefixed
    }

    /// Which networks the containers join.
    public enum Networking: String, Hashable, Sendable, CaseIterable {
        /// The runtime's built-in `default` network; nothing is created. The only network where containers can
        /// look each other up by name on CLI 1.5.0.
        case sharedDefault
        /// The networks the file declares (created as `<project>_<name>`): isolation, but no name lookup.
        case asDeclared
    }

    /// Overrides the project name (`name:` in the file, else the folder name).
    public var projectName: String?
    /// Profiles to start in addition to the services without a profile.
    public var enabledProfiles: Set<String> = []
    public var naming: Naming = .serviceName
    public var networking: Networking = .sharedDefault
    /// Names of existing containers the user agreed to delete and recreate.
    public var replaceExisting: Set<String> = []

    /// Defaults: service names, shared default network, no profiles, nothing replaced.
    public init() {}
}

/// What already exists in the engine, captured once so planning is a pure function.
public struct ComposeEnvironment: Hashable, Sendable {
    /// An existing container, as far as collision checks care.
    public struct ExistingContainer: Hashable, Sendable {
        public var isRunning: Bool
        /// Host ports it publishes, as `port/proto`.
        public var hostPorts: Set<String>

        /// A container that is running or not, publishing `hostPorts`.
        public init(isRunning: Bool, hostPorts: Set<String> = []) {
            self.isRunning = isRunning
            self.hostPorts = hostPorts
        }
    }

    /// Existing containers by name (running and stopped: names are unique across both).
    public var containers: [String: ExistingContainer] = [:]
    public var networks: Set<String> = []
    public var volumes: Set<String> = []
    /// Local images in canonical form (`docker.io/library/redis:7`).
    public var images: Set<String> = []
    /// The engine's default DNS domain (`test`), when one is set **and** registered (`container system dns
    /// list`). Only then do containers on the `default` network resolve each other by name.
    public var dnsDomain: String?
    /// The engine's default DNS domain when it is set as a property but not registered: containers get it as
    /// their search domain, but nothing answers for it, so names do not resolve (seen on CLI 1.5.0).
    public var unregisteredDNSDomain: String?
    /// `false` when the engine could not be asked (stopped / not installed): nothing is known to exist.
    public var isLoaded = false

    /// Nothing exists, nothing is known.
    public init() {}

    /// Asks the backend for containers, networks, volumes, images and the DNS domain. Never throws: when the
    /// engine is not reachable the result has `isLoaded == false`.
    public static func load(from backend: any ContainerBackend) async -> ComposeEnvironment {
        var environment = ComposeEnvironment()
        do {
            for container in try await backend.listContainers(includeStopped: true) {
                environment.containers[container.id] = ExistingContainer(
                    isRunning: container.isRunning,
                    hostPorts: Set(container.configuration.publishedPorts.map { "\($0.hostPort)/\($0.proto)" }))
            }
            environment.networks = Set(try await backend.listNetworks().map(\.name))
            environment.volumes = Set(try await backend.listVolumes().map(\.name))
            environment.images = Set(try await backend.listImages().map { ImageReferenceName.canonical($0.reference) })
            environment.isLoaded = true
        } catch {
            return ComposeEnvironment()
        }
        guard let domain = try? await backend.systemProperties().dns?.domain, !domain.isEmpty else {
            return environment
        }
        // A failed `dns list` counts as "not registered": the preview must not promise names that may not work.
        let registered = (try? await backend.listDNSDomains())?.contains { $0.domain == domain } ?? false
        if registered { environment.dnsDomain = domain } else { environment.unregisteredDNSDomain = domain }
        return environment
    }
}

/// One command of the plan.
public struct ComposeStep: Hashable, Sendable, Identifiable {
    /// What the step does; each case maps onto one backend call.
    public enum Action: Hashable, Sendable {
        case createNetwork(name: String, subnet: String?, subnetV6: String?, labels: [String: String])
        case createVolume(name: String, labels: [String: String])
        case pullImage(reference: String, platform: Platform?)
        case buildImage(BuildSpec)
        /// Deletes an existing container (killed first when running) so its name can be reused.
        case removeContainer(name: String)
        case runContainer(RunSpec)
        /// Runs `container`'s health check inside it until it passes (`depends_on: condition: service_healthy`).
        case waitHealthy(container: String, check: ComposeHealthcheck)
        /// Waits until `container` has stopped (`condition: service_completed_successfully`).
        case waitCompleted(container: String)

        /// Whether the action only waits (nothing is created or changed).
        public var isWait: Bool {
            switch self {
            case .waitHealthy, .waitCompleted: return true
            default: return false
            }
        }
    }

    /// Stable within a plan: `network:shop_default`, `run:db`.
    public var id: String
    public var action: Action
    /// The service the step belongs to, when it belongs to one.
    public var service: String?

    /// A step with a stable `id`.
    public init(id: String, action: Action, service: String? = nil) {
        self.id = id
        self.action = action
        self.service = service
    }

    /// Short description for the step list ("Create volume shop_pgdata").
    public var title: String {
        switch action {
        case .createNetwork(let name, _, _, _): return "Create network \(name)"
        case .createVolume(let name, _): return "Create volume \(name)"
        case .pullImage(let reference, _): return "Pull \(reference)"
        case .buildImage(let spec): return "Build \(spec.tag)"
        case .removeContainer(let name): return "Delete existing container \(name)"
        case .runContainer(let spec): return "Run \(spec.name ?? spec.image)"
        case .waitHealthy(let container, _): return "Wait for \(container) to be healthy"
        case .waitCompleted(let container): return "Wait for \(container) to finish"
        }
    }

    /// Whether the step only waits (nothing is created or changed).
    public var isWait: Bool { action.isWait }

    /// SF Symbol for the step list.
    public var symbol: String {
        switch action {
        case .createNetwork: return "network"
        case .createVolume: return "externaldrive"
        case .pullImage: return "arrow.down.circle"
        case .buildImage: return "hammer"
        case .removeContainer: return "trash"
        case .runContainer: return "play.circle"
        case .waitHealthy: return "waveform.path.ecg"
        case .waitCompleted: return "hourglass"
        }
    }

    /// The equivalent `container …` command as a shell-quoted one-liner. `maskSecrets` hides sensitive
    /// environment values the same way the Run sheet does. (For pull and run the app also passes
    /// `--progress plain` so output can be streamed; that flag is left out here.)
    public func commandLine(maskSecrets: Bool = true) -> String {
        switch action {
        case .createNetwork(let name, let subnet, let subnetV6, let labels):
            var words = ["container", "network", "create"]
            if let subnet { words += ["--subnet", subnet] }
            if let subnetV6 { words += ["--subnet-v6", subnetV6] }
            words += Self.labelArguments(labels) + ["--", name]
            return ShellWords.join(words)
        case .createVolume(let name, let labels):
            return ShellWords.join(["container", "volume", "create"] + Self.labelArguments(labels) + ["--", name])
        case .pullImage(let reference, let platform):
            let platformArguments = platform.map { ["--platform", $0.slug] } ?? []
            return ShellWords.join(["container", "image", "pull"] + platformArguments + ["--", reference])
        case .buildImage(let spec):
            return ShellWords.join(["container", "build"] + spec.cliArguments)
        case .removeContainer(let name):
            return ShellWords.join(["container", "delete", "-f", "--", name])
        case .runContainer(let spec):
            return spec.commandLineString(maskSecrets: maskSecrets)
        case .waitHealthy(let container, let check):
            // What the app does, as a shell loop (without the timeout, retry limit and start period it applies).
            let probe = ShellWords.join(["container", "exec", "--", container] + check.command)
            return "until \(probe); do sleep \(Self.seconds(check.interval)); done"
        case .waitCompleted(let container):
            return "while container list --quiet | grep -qx \(ShellWords.quote(container)); do sleep 1; done"
        }
    }

    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func labelArguments(_ labels: [String: String]) -> [String] {
        labels.sorted { $0.key < $1.key }.flatMap { ["--label", "\($0.key)=\($0.value)"] }
    }
}

/// Something that stops the plan from running until the user changes the file or an option.
public struct ComposeProblem: Hashable, Sendable, Identifiable {
    /// What kind of problem, for the ones the preview can fix with one click.
    public enum Kind: Hashable, Sendable {
        /// A container with this name already exists; the preview offers to replace it.
        case containerExists(name: String)
        case other
    }

    public var kind: Kind
    public var message: String
    /// The service concerned, when there is one.
    public var service: String?

    public var id: String { "\(service ?? "")|\(message)" }

    /// A blocking problem.
    public init(_ message: String, service: String? = nil, kind: Kind = .other) {
        self.kind = kind
        self.message = message
        self.service = service
    }
}

/// How one service of the file ends up in the plan.
public struct ComposeServiceSummary: Hashable, Sendable, Identifiable {
    /// Service key in the file.
    public var name: String
    /// Container name it gets, which is also its hostname.
    public var containerName: String
    /// Image it runs (the built tag for services with `build:`).
    public var image: String
    /// Whether the image is built from a Dockerfile first.
    public var isBuilt: Bool
    /// `false` for services left out because none of their profiles is enabled.
    public var isEnabled: Bool
    /// Profiles the service belongs to.
    public var profiles: [String]
    /// Published ports, as `host→container/proto`.
    public var ports: [String]
    /// Names other containers of the stack can use to reach it. Empty when only the IP address works.
    public var hostnames: [String]
    /// The health check the app can run for it, when the file gives one.
    public var healthcheck: ComposeHealthcheck?
    /// Restart policy the container is labelled with.
    public var restart: RestartPolicy = .no
    /// What it waits for before it starts, e.g. "db to be healthy", "migrate to finish".
    public var waitsFor: [String] = []

    public var id: String { name }
}

/// The ordered, inspectable result of planning a compose file: what will be created and run, in order, plus
/// everything that will differ from `docker compose up` and everything that blocks the run.
public struct ComposePlan: Hashable, Sendable {
    /// Project name used for labels and resource prefixes.
    public var projectName: String
    /// Commands in execution order: networks, volumes, images, then containers in dependency order.
    public var steps: [ComposeStep] = []
    /// One row per service of the file, in file order.
    public var services: [ComposeServiceSummary] = []
    /// Networks and volumes that already exist and are used as they are, e.g. "volume shop_pgdata".
    public var reused: [String] = []
    /// Parser warnings plus the planner's own notes, grouped by scope in the preview.
    public var warnings: [ComposeWarning] = []
    /// Blocking problems. The plan can run only when this is empty.
    public var problems: [ComposeProblem] = []
    /// One paragraph for the preview: how the services reach each other by name with these options.
    public var namingSummary: String = ""

    /// A plan with no steps yet.
    public init(projectName: String) { self.projectName = projectName }

    /// Whether Run can be offered.
    public var canRun: Bool {
        problems.isEmpty && steps.contains { if case .runContainer = $0.action { true } else { false } }
    }

    /// Names of the containers the plan deletes before recreating them.
    public var containersToReplace: [String] {
        steps.compactMap { if case .removeContainer(let name) = $0.action { name } else { nil } }
    }

    /// Names of the containers the plan starts, in start order.
    public var containerNames: [String] {
        steps.compactMap { if case .runContainer(let spec) = $0.action { spec.name } else { nil } }
    }

    /// Every command, one per line, for "Copy all".
    public func script(maskSecrets: Bool) -> String {
        steps.map { $0.commandLine(maskSecrets: maskSecrets) }.joined(separator: "\n")
    }

    /// Whether any step carries a secret that `script(maskSecrets: true)` hides.
    public var containsSecrets: Bool { script(maskSecrets: true) != script(maskSecrets: false) }
}
