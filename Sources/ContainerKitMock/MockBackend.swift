import ContainerKit
import Foundation

/// In-memory backend seeded from recorded fixtures. State mutates realistically (start/stop/delete
/// change the list) so the UI can be developed and tested without the container system.
public actor MockBackend: ContainerBackend {
    public nonisolated let backendDescription = MockBackend.description()

    /// "Mock (fixtures 1.5.0)". DEBUG builds may override it with `CONTAINER_DESKTOP_MOCK_DESCRIPTION` so marketing
    /// screenshots of the mock show the label a real install shows (e.g. "CLI (/usr/local/bin/container)").
    private static func description() -> String {
        #if DEBUG
            if let custom = ProcessInfo.processInfo.environment["CONTAINER_DESKTOP_MOCK_DESCRIPTION"], !custom.isEmpty {
                return custom
            }
        #endif
        return "Mock (fixtures 1.5.0)"
    }

    public var containers: [Container]
    public var images: [Image]
    public var volumes: [Volume]
    public var networks: [Network]
    public var machines: [Machine]
    public var clusters: [KubernetesCluster] = []
    /// Which Kubernetes plugin the mock plays: `.legacy` (container 1.5.0's `k8s`), `.modern` (1.7's `cluster`)
    /// or `nil` (no plugin). Also decides whether stats carry `cpuUtilization`, as a 1.7 CLI's do.
    public var kubernetes: KubernetesCapabilities?
    public var registries: [RegistryLogin] = [
        RegistryLogin(server: "docker.io", username: "you"), RegistryLogin(server: "ghcr.io", username: "you"),
    ]
    public var dnsDomains: [DNSDomain] = [DNSDomain(domain: "test")]
    public var properties: SystemProperties
    public var status: SystemStatus
    public var configTOML = """
        [container]
        cpus = 4
        memory = "2G"

        [build]
        cpus = 4
        memory = "4G"

        [machine]
        cpus = 6
        memory = "8G"

        [dns]
        domain = "test"

        """
    /// Simulated latency so loading states are visible in previews.
    public var latency: Duration = .milliseconds(60)
    public var systemRunning = true
    /// Fake filesystems for the Files tab by container id, built on first use (`MockBackend+Files.swift`).
    var fileSystems: [String: MockFileSystem] = [:]
    /// What runs in each cluster, by cluster name, seeded on first use (`MockBackend+Workloads.swift`).
    var workloadStates: [String: ClusterWorkloads] = [:]
    /// Scripted `execCapture` results (health-check tests); see `MockBackend+Simulation.swift`.
    var execHandler: ExecHandler?
    /// Ids whose next `startContainer` calls fail (restart-policy tests).
    var failingStarts = Set<String>()
    /// The time a container start is stamped with (tests replace it with a fake clock).
    var currentDate: @Sendable () -> Date = { .now }
    /// How many times `startContainer` succeeded per id.
    public internal(set) var startCounts: [String: Int] = [:]
    /// Whether the mock pretends its runtime has `container commit` (Apple container 1.6+).
    public var commitSupported = true
    /// Whether the mock pretends its runtime has `container clean` (Apple container 1.7+): yes when it plays a
    /// 1.7 CLI, no when it plays 1.5.0. See `MockBackend+Clean.swift`.
    public var cleanSupported: Bool
    /// The ids `cleanContainers` has cleaned, in order (tests).
    public internal(set) var cleanedContainers: [String] = []
    /// Origin of the fake stats counters (see `containerStats`).
    private let statsEpoch = Date.now

    /// - Parameter kubernetes: the plugin to play; 1.5.0's unless `CONTAINER_DESKTOP_MOCK_CLI` says otherwise
    ///   (`1.7` plays the new `cluster` plugin, `none` plays a CLI without one).
    public init(kubernetes: KubernetesCapabilities? = MockBackend.environmentKubernetes()) {
        self.kubernetes = kubernetes
        cleanSupported = kubernetes?.listsJSON == true
        clusters = MockClusters.seed(for: kubernetes)
        containers = (try? MockBackend.scrubbed([Container].self, "containers.json")) ?? []
        images = (try? Fixtures.images()) ?? []
        volumes = (try? MockBackend.scrubbed([Volume].self, "volumes.json")) ?? []
        networks = (try? Fixtures.networks()) ?? []
        machines = (try? MockBackend.scrubbed([Machine].self, "machines.json")) ?? []
        properties = (try? MockBackend.scrubbed(SystemProperties.self, "system-properties.json")) ?? SystemProperties()
        status = (try? MockBackend.scrubbed(SystemStatus.self, "system-status.json")) ?? SystemStatus(status: "running")
        containers += MockBackend.extraContainers()
        images += MockBackend.extraImages()
        volumes += MockBackend.extraVolumes()
        networks += MockBackend.extraNetworks()
    }

    private func wait() async { try? await Task.sleep(for: latency) }

    private func requireRunning() throws { if !systemRunning { throw BackendError.systemNotRunning } }

    private nonisolated func stream(
        _ lines: [String], delay: Duration = .milliseconds(80), then finish: (@Sendable () async -> Void)? = nil
    ) -> LineStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                for line in lines {
                    try Task.checkCancellation()
                    continuation.yield(OutputLine(line))
                    try await Task.sleep(for: delay)
                }
                await finish?()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: System

    public func systemStatus() async throws -> SystemStatus {
        await wait()
        var s = status
        s.status = systemRunning ? "running" : "stopped"
        s.resources = .init(
            containersRunning: containers.filter(\.isRunning).count, containersTotal: containers.count,
            images: images.count)
        return s
    }
    public func systemStart() async throws { await wait(); systemRunning = true }
    public func systemStop() async throws { await wait(); systemRunning = false }
    public func systemProperties() async throws -> SystemProperties {
        try requireRunning(); await wait(); return properties
    }
    public func diskUsage() async throws -> DiskUsage {
        try requireRunning(); await wait()
        return DiskUsage(
            containers: .init(
                total: containers.count, active: containers.filter(\.isRunning).count, sizeInBytes: 3_488_817_152,
                reclaimable: 210_000_000),
            images: .init(total: images.count, active: 3, sizeInBytes: 17_965_199_360, reclaimable: 15_191_203_840),
            volumes: .init(total: volumes.count, active: 1, sizeInBytes: 69_390_336, reclaimable: 0))
    }
    public func systemLogs(lines: Int) async throws -> [OutputLine] {
        await wait()
        return (0..<min(lines, 40)).map {
            OutputLine(
                "2026-10-17 18:46:\(String(format: "%02d", $0)) container-apiserver: [APIServer] Handling container request #\($0)"
            )
        }
    }
    public func listDNSDomains() async throws -> [DNSDomain] { await wait(); return dnsDomains }
    public func createDNSDomain(_ domain: String, localhostAddress: String?) async throws {
        await wait(); dnsDomains.append(DNSDomain(domain: domain, localhostAddress: localhostAddress))
    }
    public func deleteDNSDomain(_ domain: String) async throws {
        await wait(); dnsDomains.removeAll { $0.domain == domain }
    }
    public func readConfigTOML() async throws -> String { await wait(); return configTOML }
    public func writeConfigTOML(_ text: String) async throws { await wait(); configTOML = text }

    // MARK: Containers

    public func listContainers(includeStopped: Bool) async throws -> [Container] {
        try requireRunning(); await wait()
        return includeStopped ? containers : containers.filter(\.isRunning)
    }
    public func inspectContainer(_ id: String) async throws -> Container {
        try requireRunning(); await wait()
        guard let c = containers.first(where: { $0.id == id }) else {
            throw BackendError.notFound(kind: "container", id: id)
        }
        return c
    }
    public nonisolated func runContainer(_ spec: RunSpec) -> LineStream {
        let id = spec.name ?? UUID().uuidString.lowercased()
        return stream(["[1/6] Fetching image", "[2/6] Unpacking image", "[6/6] Starting container", id]) { [self] in
            _ = try? await self.createContainer(spec, id: id, running: true)
        }
    }
    public func createContainer(_ spec: RunSpec) async throws -> String {
        try await createContainer(spec, id: spec.name ?? UUID().uuidString.lowercased(), running: false)
    }
    private func createContainer(_ spec: RunSpec, id: String, running: Bool) async throws -> String {
        try requireRunning(); await wait()
        guard !containers.contains(where: { $0.id == id }) else {
            throw BackendError.commandFailed(
                command: "container run", exitCode: 1, message: "container with id \(id) already exists")
        }
        let desc = Descriptor(
            digest: "sha256:" + MockBackend.fakeDigest(spec.image),
            mediaType: "application/vnd.oci.image.index.v1+json", size: 1000)
        let config = Container.Configuration(
            id: id, image: ImageReference(reference: spec.image, descriptor: desc), creationDate: .now,
            resources: .init(cpus: spec.cpus ?? 4, memoryInBytes: spec.memory?.bytes ?? (1 << 30)),
            initProcess: .init(
                executable: spec.command.first ?? "sh", arguments: Array(spec.command.dropFirst()),
                environment: spec.environment),
            labels: spec.labels,
            publishedPorts: spec.ports.map {
                .init(
                    hostAddress: $0.hostAddress ?? "127.0.0.1", hostPort: $0.hostPort, containerPort: $0.containerPort,
                    proto: $0.proto)
            })
        let st =
            running
            ? Container.Status(
                state: .running, startedDate: .now,
                networks: [.init(hostname: "\(id).test.", ipv4Address: "192.168.64.\(50 + containers.count)/24")])
            : Container.Status(state: .stopped)
        containers.append(Container(id: id, configuration: config, status: st))
        return id
    }
    func update(_ id: String, _ body: (inout Container) -> Void) throws {
        guard let i = containers.firstIndex(where: { $0.id == id }) else {
            throw BackendError.notFound(kind: "container", id: id)
        }
        body(&containers[i])
    }
    public func startContainer(_ id: String) async throws {
        try requireRunning(); await wait()
        if failingStarts.contains(id) {
            throw BackendError.commandFailed(
                command: "container start \(id)", exitCode: 1, message: "failed to start container \(id)")
        }
        startCounts[id, default: 0] += 1
        let date = currentDate()
        try update(id) {
            $0.status = Container.Status(
                state: .running, startedDate: date,
                networks: [.init(hostname: "\(id).test.", ipv4Address: "192.168.64.60/24")])
        }
    }
    public func stopContainer(_ id: String, timeoutSeconds: Int?, signal: String?) async throws {
        try requireRunning(); await wait()
        // Like the real runtime, a stopped container keeps the date of its last start.
        try update(id) { $0.status = Container.Status(state: .stopped, startedDate: $0.status?.startedDate) }
    }
    public func killContainer(_ id: String, signal: String?) async throws {
        try await stopContainer(id, timeoutSeconds: nil, signal: signal)
    }
    public func deleteContainer(_ id: String, force: Bool) async throws {
        try requireRunning(); await wait()
        guard let c = containers.first(where: { $0.id == id }) else {
            throw BackendError.notFound(kind: "container", id: id)
        }
        if c.isRunning && !force {
            throw BackendError.commandFailed(
                command: "container rm", exitCode: 1, message: "container \(id) is running; stop it or use force")
        }
        containers.removeAll { $0.id == id }
    }
    public func pruneContainers() async throws {
        try requireRunning(); await wait(); containers.removeAll { !$0.isRunning }
    }
    public nonisolated func containerLogs(_ id: String, follow: Bool, boot: Bool, tail: Int?) -> LineStream {
        let lines: [String] =
            boot
            ? (0..<30).map { "[    0.\(String(format: "%06d", $0 * 4321))] virtio_blk virtio2: [vda] boot step \($0)" }
            : MockBackend.sampleLogs(for: id, count: tail ?? 200)
        return stream(lines, delay: follow ? .milliseconds(300) : .zero)
    }
    public func containerStats(ids: [String]) async throws -> [ContainerStats] {
        try requireRunning(); await wait()
        let t = Date.now.timeIntervalSince(statsEpoch)
        let running = containers.filter(\.isRunning)
        return running.enumerated().filter { ids.isEmpty || ids.contains($0.element.id) }.map { i, c in
            // Counters are a closed-form integral of a smooth rate curve over wall-clock time, so every poller
            // (list, detail, menu bar) sees the same consistent rates no matter how often it samples.
            let phase = Double(i) * 1.7
            func integral(_ rate: Double, _ phase: Double) -> Int64 {
                let p1 = 9.0, p2 = 3.7  // seconds; rate(t) = rate * (1 + 0.7 sin(t/p1) + 0.25 sin(t/p2)) > 0
                return Int64(
                    rate * (t + 0.7 * p1 * (1 - cos(t / p1 + phase)) + 0.25 * p2 * (1 - cos(t / p2 + phase * 2))))
            }
            let wave = 0.5 + 0.3 * sin(t / 9 + phase) + 0.2 * sin(t / 3.7 + phase * 2)  // 0…1
            return ContainerStats(
                id: c.id, cpuUsageUsec: integral(Double(30_000 + i * 15_000), phase),
                memoryUsageBytes: Int64(38_000_000 + i * 90_000_000) + Int64(wave * 14_000_000),
                memoryLimitBytes: c.configuration.resources.memoryInBytes,
                networkRxBytes: integral(Double(1_200 + i * 450), phase),
                networkTxBytes: integral(Double(450 + i * 200), phase + 2.2),
                blockReadBytes: 21_660_672, blockWriteBytes: integral(Double(6_000 + i * 1_000), phase + 4.1),
                numProcesses: 1 + i * 5,
                cpuUtilization: MockClusters.cpuUtilization(kubernetes, index: i, time: t, phase: phase))
        }
    }
    public func execCapture(
        _ id: String, command: [String], workingDirectory: String?
    ) async throws -> (exitCode: Int32, stdout: String, stderr: String) {
        try requireRunning(); await wait()
        if let execHandler { return await execHandler(id, command) }
        return (0, "mock output of: \(command.joined(separator: " "))\n", "")
    }
    public func copy(from source: String, to destination: String) async throws { await wait() }
    public func exportContainer(_ id: String, to tarPath: String) async throws { await wait() }
    public nonisolated func terminalCommand(for target: TerminalTarget) -> CommandLine {
        switch target {
        case .container(let id, let command):
            return CommandLine(executable: "/usr/local/bin/container", arguments: ["exec", "-it", "--", id] + command)
        case .machine(let name):
            return CommandLine(executable: "/usr/local/bin/container", arguments: ["machine", "run", "-n", name])
        case .shell: return CommandLine(executable: "/bin/zsh", arguments: ["-l"])
        }
    }

    // MARK: Images

    public func listImages() async throws -> [Image] { try requireRunning(); await wait(); return images }
    public func inspectImage(_ reference: String) async throws -> Image {
        try requireRunning(); await wait()
        guard
            let i = images.first(where: {
                $0.reference == reference || $0.repository == reference || $0.id.hasPrefix(reference)
            })
        else {
            throw BackendError.notFound(kind: "image", id: reference)
        }
        return i
    }
    public nonisolated func pullImage(_ reference: String, platform: Platform?, scheme: String?) -> LineStream {
        stream([
            "Fetching \(reference)", "[1/3] Fetching manifest", "[2/3] Fetching layers 12.3 MB / 55.0 MB",
            "[2/3] Fetching layers 55.0 MB / 55.0 MB", "[3/3] Unpacking image", "Done",
        ]) { [self] in
            await self.addImage(reference)
        }
    }
    private func addImage(_ reference: String) {
        guard !images.contains(where: { $0.reference == reference }) else { return }
        let desc = Descriptor(
            digest: "sha256:" + MockBackend.fakeDigest(reference),
            mediaType: "application/vnd.oci.image.index.v1+json", size: 500)
        images.append(
            Image(
                id: MockBackend.fakeDigest(reference),
                configuration: .init(name: reference, creationDate: .now, descriptor: desc),
                variants: [.init(platform: .arm64, digest: desc.digest, size: 55_000_000)]))
    }
    public nonisolated func pushImage(_ reference: String, platform: Platform?, scheme: String?) -> LineStream {
        stream(["Pushing \(reference)", "Pushing layer 1/6", "Pushing layer 6/6", "Pushing manifest", "Done"])
    }
    public func deleteImage(_ reference: String) async throws {
        try requireRunning(); await wait()
        guard images.contains(where: { $0.reference == reference }) else {
            throw BackendError.notFound(kind: "image", id: reference)
        }
        images.removeAll { $0.reference == reference }
    }
    public func tagImage(_ reference: String, newReference: String) async throws {
        try requireRunning(); await wait()
        guard var img = images.first(where: { $0.reference == reference }) else {
            throw BackendError.notFound(kind: "image", id: reference)
        }
        img.configuration.name = newReference
        images.append(img)
    }
    public func pruneImages(all: Bool) async throws {
        try requireRunning(); await wait()
        let used = Set(containers.map(\.imageReference))
        images.removeAll { !used.contains($0.reference) && (all || $0.tag == nil) }
    }
    public func saveImages(_ references: [String], to tarPath: String, platform: Platform?) async throws {
        await wait()
    }
    public func loadImages(from tarPath: String) async throws { await wait() }
    public nonisolated func buildImage(_ spec: BuildSpec) -> LineStream {
        stream(
            [
                "#1 [internal] load build definition from Dockerfile", "#1 DONE 0.0s",
                "#2 [internal] load metadata for docker.io/library/python:3.11-slim",
                "#2 DONE 1.2s", "#3 [1/3] FROM docker.io/library/python:3.11-slim", "#3 DONE 0.1s",
                "#4 [2/3] RUN pip install fastapi", "#4 12.3 Collecting fastapi",
                "#4 DONE 14.1s", "#5 [3/3] COPY app.py /app.py", "#5 DONE 0.0s", "#6 exporting to image",
                "#6 exporting manifest list sha256:8d42…", "#6 DONE 0.2s", spec.tag,
            ],
            delay: .milliseconds(150)
        ) { [self] in await self.addImage(spec.tag) }
    }
    public func builderStatus() async throws -> Container? {
        try requireRunning(); await wait(); return try? MockBackend.scrubbed([Container].self, "builder.json").first
    }
    public func builderStart(cpus: Int?, memory: MemorySize?) async throws { await wait() }
    public func builderStop() async throws { await wait() }
    public func builderDelete() async throws { await wait() }

    // MARK: Volumes

    public func listVolumes() async throws -> [Volume] { try requireRunning(); await wait(); return volumes }
    public func inspectVolume(_ name: String) async throws -> Volume {
        try requireRunning(); await wait()
        guard let v = volumes.first(where: { $0.name == name }) else {
            throw BackendError.notFound(kind: "volume", id: name)
        }
        return v
    }
    public func createVolume(name: String, size: MemorySize?, journal: String?, labels: [String: String]) async throws {
        try requireRunning(); await wait()
        volumes.append(
            Volume(
                id: name,
                configuration: .init(
                    name: name, creationDate: .now, labels: labels, sizeInBytes: size?.bytes ?? (512 << 30),
                    source: "~/Library/Application Support/com.apple.container/volumes/\(name)/volume.img")))
    }
    public func deleteVolume(_ name: String) async throws {
        try requireRunning(); await wait()
        if containers.contains(where: { $0.configuration.mounts.contains { $0.type.volumeName == name } }) {
            throw BackendError.commandFailed(
                command: "container volume rm", exitCode: 1, message: "volume \(name) is in use")
        }
        volumes.removeAll { $0.name == name }
    }
    public func pruneVolumes() async throws {
        try requireRunning(); await wait()
        let used = Set(containers.flatMap { $0.configuration.mounts.compactMap { $0.type.volumeName } })
        volumes.removeAll { !used.contains($0.name) }
    }

    // MARK: Networks

    public func listNetworks() async throws -> [Network] { try requireRunning(); await wait(); return networks }
    public func inspectNetwork(_ name: String) async throws -> Network {
        try requireRunning(); await wait()
        guard let n = networks.first(where: { $0.name == name }) else {
            throw BackendError.notFound(kind: "network", id: name)
        }
        return n
    }
    public func createNetwork(name: String, subnet: String?, subnetV6: String?, labels: [String: String]) async throws {
        try requireRunning(); await wait()
        networks.append(
            Network(
                id: name, configuration: .init(name: name, creationDate: .now, labels: labels),
                status: .init(
                    ipv4Gateway: "192.168.65.1", ipv4Subnet: subnet ?? "192.168.65.0/24", ipv6Subnet: subnetV6)))
    }
    public func deleteNetwork(_ name: String) async throws {
        try requireRunning(); await wait()
        if name == "default" {
            throw BackendError.commandFailed(
                command: "container network rm", exitCode: 1, message: "cannot delete the builtin network")
        }
        networks.removeAll { $0.name == name }
    }
    public func pruneNetworks() async throws {
        try requireRunning(); await wait(); networks.removeAll { !$0.isBuiltin }
    }

    // MARK: Registries

    public func listRegistries() async throws -> [RegistryLogin] { await wait(); return registries }
    public func registryLogin(server: String, username: String, password: String, scheme: String?) async throws {
        await wait()
        registries.removeAll { $0.server == server }
        registries.append(RegistryLogin(server: server, username: username, scheme: scheme))
    }
    public func registryLogout(server: String) async throws {
        await wait(); registries.removeAll { $0.server == server }
    }

    // MARK: Machines

    public func listMachines() async throws -> [Machine] {
        try requireRunning(); await wait()
        if machines.isEmpty {
            machines = [
                Machine(
                    id: "dev", status: .stopped, cpus: 8, memory: 16 << 30, diskSize: 1_169_506_304, isDefault: true,
                    createdDate: .now,
                    image: ImageReference(
                        reference: "ghcr.io/linuxcontainers/alpine:3.20",
                        descriptor: Descriptor(digest: "sha256:28a3", mediaType: "", size: 0)))
            ]
        }
        return machines
    }
    public func inspectMachine(_ name: String) async throws -> Machine {
        guard let m = try await listMachines().first(where: { $0.id == name }) else {
            throw BackendError.notFound(kind: "machine", id: name)
        }
        return m
    }
    public nonisolated func createMachine(_ spec: MachineSpec) -> LineStream {
        stream(["[1/3] Fetching image", "[2/3] Unpacking image", "[3/3] Creating machine", spec.name]) { [self] in
            await self.appendMachine(spec)
        }
    }
    private func appendMachine(_ spec: MachineSpec) {
        machines.append(
            Machine(
                id: spec.name, status: spec.noBoot ? .stopped : .running, cpus: spec.cpus ?? 4,
                memory: spec.memory?.bytes ?? (8 << 30),
                diskSize: 1_169_506_304, isDefault: spec.setDefault, createdDate: .now,
                image: ImageReference(
                    reference: spec.image, descriptor: Descriptor(digest: "sha256:0", mediaType: "", size: 0))))
    }
    public func stopMachine(_ name: String) async throws {
        await wait()
        guard let i = machines.firstIndex(where: { $0.id == name }) else {
            throw BackendError.notFound(kind: "machine", id: name)
        }
        machines[i].status = .stopped
    }
    public func deleteMachine(_ name: String) async throws { await wait(); machines.removeAll { $0.id == name } }
    public func setDefaultMachine(_ name: String) async throws {
        await wait()
        for i in machines.indices { machines[i].isDefault = machines[i].id == name }
    }
    public func configureMachine(_ name: String, settings: [String: String]) async throws {
        await wait()
        guard let i = machines.firstIndex(where: { $0.id == name }) else {
            throw BackendError.notFound(kind: "machine", id: name)
        }
        if let c = settings["cpus"].flatMap(Int.init) { machines[i].cpus = c }
        if let m = settings["memory"].flatMap({ MemorySize(parsing: $0) }) { machines[i].memory = m.bytes }
    }
    public func machineLogs(_ name: String) async throws -> [OutputLine] {
        await wait()
        return [
            "OpenRC 0.62.6 is starting up Linux 6.18.35 (aarch64)", " * Mounting /run ... [ ok ]",
            " * Caching service dependencies ... [ ok ]",
        ].map { OutputLine($0) }
    }

    // MARK: Kubernetes

    public func kubernetesAvailable() async -> Bool { kubernetes != nil }
    public func checkKubernetesAvailable() async throws -> Bool { try requireRunning(); return kubernetes != nil }
    public func kubernetesCapabilities() async throws -> KubernetesCapabilities? {
        try requireRunning(); return kubernetes
    }
    /// Switches the plugin the mock plays (tests, previews); `nil` plays a CLI without it.
    public func setKubernetes(_ capabilities: KubernetesCapabilities?) { kubernetes = capabilities }
    /// The plugin `CONTAINER_DESKTOP_MOCK_CLI` asks for (1.5.0's when unset).
    public static func environmentKubernetes() -> KubernetesCapabilities? { MockClusters.environmentCapabilities() }
    public func listClusters() async throws -> [KubernetesCluster] {
        try requireRunning(); await wait(); return clusters
    }
    /// Like the CLI backend: options the played plugin lacks fail with `.unsupported` before anything is created.
    public nonisolated func createCluster(_ spec: ClusterSpec) -> LineStream {
        prepared { backend in
            let capabilities = try await backend.requireKubernetes()
            if let error = spec.unsupportedOption(for: capabilities) { throw error }
            return backend.stream(MockClusters.createLines(spec), delay: .milliseconds(200)) {
                await backend.appendCluster(MockClusters.cluster(for: spec, capabilities: capabilities))
            }
        }
    }
    private func appendCluster(_ cluster: KubernetesCluster) {
        clusters.removeAll { $0.name == cluster.name }
        clusters.append(cluster)
    }
    private func requireKubernetes() throws -> KubernetesCapabilities {
        guard let kubernetes else {
            throw BackendError.unsupported(feature: "Kubernetes", reason: "the mock plays a CLI without the plugin.")
        }
        return kubernetes
    }
    /// A stream that first asks the actor for something (the played capabilities), then forwards `make`'s lines.
    private nonisolated func prepared(
        _ make: @escaping @Sendable (MockBackend) async throws -> LineStream
    ) -> LineStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in try await make(self) { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func deleteCluster(_ name: String) async throws { await wait(); clusters.removeAll { $0.name == name } }
    public nonisolated func loadImage(
        _ reference: String, intoCluster cluster: String?, nodes: [String], platform: Platform?
    ) -> LineStream {
        prepared { backend in
            let capabilities = try await backend.requireKubernetes()
            guard capabilities.supportsLoadImage, nodes.isEmpty || capabilities.supportsLoadImageNodes else {
                throw BackendError.unsupported(
                    feature: "Loading an image into a cluster",
                    reason: "`\(capabilities.displayCommand)` cannot do that in this CLI version.")
            }
            let target = cluster ?? capabilities.defaultClusterName
            return backend.stream([
                "Exporting \(reference)", "Importing into \(target) containerd (k8s.io namespace)", "Done",
            ])
        }
    }
}
