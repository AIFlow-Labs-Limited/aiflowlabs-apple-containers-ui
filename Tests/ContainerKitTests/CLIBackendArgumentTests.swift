import Foundation
import Testing
@testable import ContainerKit
import ContainerKitMock

/// Exact argv for every `ContainerBackend` method, recorded through a fake runner.
@Suite("CLIBackend argv")
struct CLIBackendArgumentTests {
    /// Answers each command with a fixture-shaped stdout so decoding succeeds.
    static let fixtureHandler: RecordingRunner.Handler = { arguments in
        let args = Array(arguments.dropFirst())
        func fixture(_ name: String) -> ProcessResult { ProcessResult(stdout: Fixtures.data(name)) }
        switch args.prefix(3).joined(separator: " ") {
        case "system status --format": return fixture("system-status.json")
        case "system property ls": return fixture("system-properties.json")
        case "system df --format": return fixture("system-df.json")
        case "image inspect --": return fixture("image-inspect.json")
        case "volume inspect --": return fixture("volume-inspect.json")
        case "network inspect --": return fixture("network-inspect.json")
        case "machine inspect --": return fixture("machines.json")
        case "create --name web": return ProcessResult(stdout: "web\n")
        case "k8s ls": return fixture("k8s-list.txt")
        default: break
        }
        if args.first == "inspect" { return fixture("container-inspect.json") }
        if args == ["system", "logs", "--last", "1h"] { return ProcessResult(stdout: "l1\nl2\nl3\n") }
        return ProcessResult(stdout: "[]")
    }

    func makeBackend() throws -> (CLIBackend, RecordingRunner) {
        let runner = RecordingRunner(handler: Self.fixtureHandler)
        return (try CLIBackend.recording(runner), runner)
    }

    @Test func systemCommands() async throws {
        let (backend, runner) = try makeBackend()
        _ = try await backend.systemStatus()
        try await backend.systemStart()
        try await backend.systemStop()
        _ = try await backend.systemProperties()
        _ = try await backend.diskUsage()
        let logs = try await backend.systemLogs(lines: 2)
        #expect(logs.map(\.text) == ["l2", "l3"])
        _ = try await backend.listDNSDomains()
        try await backend.createDNSDomain("test", localhostAddress: "203.0.113.7")
        try await backend.deleteDNSDomain("test")
        let calls = runner.calls.map(\.arguments)
        #expect(Array(calls.prefix(7)).map { Array($0.dropFirst()) } == [
            ["system", "status", "--format", "json"],
            ["system", "start", "--enable-kernel-install"],
            ["system", "stop"],
            ["system", "property", "ls", "--format", "json"],
            ["system", "df", "--format", "json"],
            ["system", "logs", "--last", "1h"],
            ["system", "dns", "ls", "--format", "json"],
        ])
        #expect(calls[7] == ["/usr/bin/osascript", "-e",
            #"do shell script "'/usr/local/bin/container' 'system' 'dns' 'create' '--localhost' '203.0.113.7' '--' 'test'" with administrator privileges"#])
        #expect(calls[8] == ["/usr/bin/osascript", "-e",
            #"do shell script "'/usr/local/bin/container' 'system' 'dns' 'delete' '--' 'test'" with administrator privileges"#])
    }

    @Test func dnsRejectsInjection() async throws {
        let (backend, runner) = try makeBackend()
        await #expect(throws: BackendError.self) { try await backend.createDNSDomain("x'; rm -rf ~", localhostAddress: nil) }
        await #expect(throws: BackendError.self) { try await backend.createDNSDomain("ok", localhostAddress: "1.2.3.4; id") }
        #expect(runner.calls.isEmpty)
    }

    @Test func leadingDashOperandsAreRejectedBeforeRunning() async throws {
        let (backend, runner) = try makeBackend()
        await #expect(throws: BackendError.other("Container “-a” may not start with -")) { try await backend.deleteContainer("-a", force: true) }
        await #expect(throws: BackendError.self) { try await backend.stopContainer("--all", timeoutSeconds: nil, signal: nil) }
        await #expect(throws: BackendError.self) { try await backend.deleteImage("-f") }
        await #expect(throws: BackendError.self) { try await backend.tagImage("ok:1", newReference: "-x") }
        await #expect(throws: BackendError.self) { try await backend.createVolume(name: "-v", size: nil, journal: nil, labels: [:]) }
        await #expect(throws: BackendError.self) { try await backend.deleteNetwork("-n") }
        await #expect(throws: BackendError.self) { try await backend.deleteMachine("-m") }
        await #expect(throws: BackendError.self) { try await backend.createDNSDomain("-evil", localhostAddress: nil) }
        await #expect(throws: BackendError.self) { try await backend.deleteDNSDomain("--help") }
        await #expect(throws: BackendError.self) { _ = try await backend.execCapture("-w", command: ["sh"], workingDirectory: nil) }
        let pulled = await drain(backend.pullImage("-x", platform: nil))
        #expect(pulled.error != nil)
        let logs = await drain(backend.containerLogs("-f", follow: false, boot: false, tail: nil))
        #expect(logs.error != nil)
        var spec = RunSpec(image: "--privileged")
        spec.name = "x"
        #expect(await drain(backend.runContainer(spec)).error != nil)
        #expect(runner.calls.isEmpty)
    }

    @Test func containerCommands() async throws {
        let (backend, runner) = try makeBackend()
        _ = try await backend.listContainers(includeStopped: false)
        _ = try await backend.listContainers(includeStopped: true)
        _ = try await backend.inspectContainer("web")
        var spec = RunSpec(image: "alpine")
        spec.name = "web"
        spec.command = ["echo", "hi"]
        spec.ports = [.init(hostPort: 8080, containerPort: 80)]
        _ = await drain(backend.runContainer(spec))
        let id = try await backend.createContainer(spec)
        #expect(id == "web")
        try await backend.startContainer("web")
        try await backend.stopContainer("web", timeoutSeconds: nil, signal: nil)
        try await backend.stopContainer("web", timeoutSeconds: 10, signal: "SIGINT")
        try await backend.killContainer("web", signal: nil)
        try await backend.killContainer("web", signal: "SIGHUP")
        try await backend.deleteContainer("web", force: false)
        try await backend.deleteContainer("web", force: true)
        try await backend.pruneContainers()
        _ = await drain(backend.containerLogs("web", follow: false, boot: false, tail: nil))
        _ = await drain(backend.containerLogs("web", follow: true, boot: true, tail: 50))
        _ = try await backend.containerStats(ids: [])
        _ = try await backend.containerStats(ids: ["a", "b"])
        _ = try await backend.execCapture("web", command: ["ls", "-la"], workingDirectory: nil)
        _ = try await backend.execCapture("web", command: ["pwd"], workingDirectory: "/tmp")
        try await backend.copy(from: "web:/etc/hosts", to: "/tmp/hosts")
        try await backend.exportContainer("web", to: "/tmp/web.tar")
        #expect(runner.commands == [
            ["ls", "--format", "json"],
            ["ls", "-a", "--format", "json"],
            ["inspect", "--", "web"],
            ["run", "--progress", "plain", "-d", "--name", "web", "-p", "8080:80/tcp", "alpine", "echo", "hi"],
            ["create", "--name", "web", "-p", "8080:80/tcp", "alpine", "echo", "hi"],
            ["start", "--", "web"],
            ["stop", "--", "web"],
            ["stop", "-t", "10", "-s", "SIGINT", "--", "web"],
            ["kill", "--", "web"],
            ["kill", "-s", "SIGHUP", "--", "web"],
            ["delete", "--", "web"],
            ["delete", "-f", "--", "web"],
            ["prune"],
            ["logs", "--", "web"],
            ["logs", "-f", "--boot", "-n", "50", "--", "web"],
            ["stats", "--no-stream", "--format", "json"],
            ["stats", "--no-stream", "--format", "json", "--", "a", "b"],
            ["exec", "--", "web", "ls", "-la"],
            ["exec", "-w", "/tmp", "--", "web", "pwd"],
            ["copy", "--", "web:/etc/hosts", "/tmp/hosts"],
            ["export", "--output", "/tmp/web.tar", "--", "web"],
        ])
        #expect(runner.calls[3].streamed && runner.calls[13].streamed && runner.calls[14].streamed)
    }

    @Test func imageCommands() async throws {
        let (backend, runner) = try makeBackend()
        _ = try await backend.listImages()
        _ = try await backend.inspectImage("alpine")
        _ = await drain(backend.pullImage("alpine:3.22", platform: nil))
        _ = await drain(backend.pullImage("alpine:3.22", platform: .amd64))
        _ = await drain(backend.pushImage("ghcr.io/x/y:1", platform: .arm64))
        try await backend.deleteImage("alpine:3.22")
        try await backend.tagImage("alpine:3.22", newReference: "mine:1")
        try await backend.pruneImages(all: false)
        try await backend.pruneImages(all: true)
        try await backend.saveImages(["a:1", "b:2"], to: "/tmp/i.tar", platform: nil)
        try await backend.saveImages(["a:1"], to: "/tmp/i.tar", platform: .arm64)
        try await backend.loadImages(from: "/tmp/i.tar")
        var build = BuildSpec(contextDirectory: "/src", tag: "app:dev")
        build.dockerfile = "Dockerfile.dev"
        _ = await drain(backend.buildImage(build))
        #expect(try await backend.builderStatus() == nil)
        try await backend.builderStart(cpus: nil, memory: nil)
        try await backend.builderStart(cpus: 4, memory: MemorySize(parsing: "8g"))
        try await backend.builderStop()
        try await backend.builderDelete()
        #expect(runner.commands == [
            ["image", "ls", "--format", "json"],
            ["image", "inspect", "--", "alpine"],
            ["image", "pull", "--progress", "plain", "--", "alpine:3.22"],
            ["image", "pull", "--progress", "plain", "--platform", "linux/amd64", "--", "alpine:3.22"],
            ["image", "push", "--progress", "plain", "--platform", "linux/arm64", "--", "ghcr.io/x/y:1"],
            ["image", "rm", "--", "alpine:3.22"],
            ["image", "tag", "--", "alpine:3.22", "mine:1"],
            ["image", "prune"],
            ["image", "prune", "--all"],
            ["image", "save", "--output", "/tmp/i.tar", "--", "a:1", "b:2"],
            ["image", "save", "--output", "/tmp/i.tar", "--platform", "linux/arm64", "--", "a:1"],
            ["image", "load", "--input", "/tmp/i.tar"],
            ["build", "-t", "app:dev", "--progress", "plain", "-f", "Dockerfile.dev", "/src"],
            ["builder", "status", "--format", "json"],
            ["builder", "start"],
            ["builder", "start", "-c", "4", "-m", "8G"],
            ["builder", "stop"],
            ["builder", "delete"],
        ])
    }

    @Test func volumeAndNetworkCommands() async throws {
        let (backend, runner) = try makeBackend()
        _ = try await backend.listVolumes()
        _ = try await backend.inspectVolume("v1")
        try await backend.createVolume(name: "v1", size: nil, journal: nil, labels: [:])
        try await backend.createVolume(name: "v2", size: MemorySize(parsing: "10g"), journal: "writeback:64m", labels: ["b": "2", "a": "1"])
        try await backend.deleteVolume("v1")
        try await backend.pruneVolumes()
        _ = try await backend.listNetworks()
        _ = try await backend.inspectNetwork("n1")
        try await backend.createNetwork(name: "n1", subnet: nil, subnetV6: nil, labels: [:])
        try await backend.createNetwork(name: "n2", subnet: "10.9.0.0/24", subnetV6: "fd00::/64", labels: ["k": "v"])
        try await backend.deleteNetwork("n1")
        try await backend.pruneNetworks()
        #expect(runner.commands == [
            ["volume", "ls", "--format", "json"],
            ["volume", "inspect", "--", "v1"],
            ["volume", "create", "--", "v1"],
            ["volume", "create", "-s", "10737418240", "--opt", "journal=writeback:64m", "--label", "a=1", "--label", "b=2", "--", "v2"],
            ["volume", "rm", "--", "v1"],
            ["volume", "prune"],
            ["network", "ls", "--format", "json"],
            ["network", "inspect", "--", "n1"],
            ["network", "create", "--", "n1"],
            ["network", "create", "--subnet", "10.9.0.0/24", "--subnet-v6", "fd00::/64", "--label", "k=v", "--", "n2"],
            ["network", "rm", "--", "n1"],
            ["network", "prune"],
        ])
    }

    @Test func registryCommandsKeepPasswordOutOfArgv() async throws {
        let (backend, runner) = try makeBackend()
        _ = try await backend.listRegistries()
        try await backend.registryLogin(server: "ghcr.io", username: "robot", password: "s3cr3t", scheme: nil)
        try await backend.registryLogin(server: "localhost:5000", username: "u", password: "p", scheme: "http")
        try await backend.registryLogout(server: "ghcr.io")
        #expect(runner.commands == [
            ["registry", "ls", "--format", "json"],
            ["registry", "login", "--username", "robot", "--password-stdin", "--", "ghcr.io"],
            ["registry", "login", "--scheme", "http", "--username", "u", "--password-stdin", "--", "localhost:5000"],
            ["registry", "logout", "--", "ghcr.io"],
        ])
        #expect(runner.calls[1].stdin == Data("s3cr3t\n".utf8))
        #expect(!runner.calls.flatMap(\.arguments).contains("s3cr3t"))
    }

    @Test func machineCommands() async throws {
        let (backend, runner) = try makeBackend()
        _ = try await backend.listMachines()
        let machine = try await backend.inspectMachine("m1")
        #expect(machine.id == "probe-m")
        var spec = MachineSpec(image: "ubuntu:24.04", name: "dev")
        spec.cpus = 4
        _ = await drain(backend.createMachine(spec))
        try await backend.stopMachine("m1")
        try await backend.deleteMachine("m1")
        try await backend.setDefaultMachine("m1")
        try await backend.configureMachine("m1", settings: ["memory": "8G", "cpus": "4"])
        _ = try await backend.machineLogs("m1")
        #expect(runner.commands == [
            ["machine", "ls", "--format", "json"],
            ["machine", "inspect", "--", "m1"],
            ["machine", "create", "--name", "dev", "--cpus", "4", "ubuntu:24.04"],
            ["machine", "stop", "--", "m1"],
            ["machine", "rm", "--", "m1"],
            ["machine", "set-default", "--", "m1"],
            ["machine", "set", "-n", "m1", "cpus=4", "memory=8G"],
            ["machine", "logs", "--", "m1"],
        ])
    }

    @Test func kubernetesCommands() async throws {
        let (backend, runner) = try makeBackend()
        #expect(await backend.kubernetesAvailable())
        #expect(try await backend.listClusters().map(\.name) == ["k8s-dev", "staging", "cd-ui-test"])
        var spec = ClusterSpec(name: "dev")
        spec.cpus = 4
        spec.memory = MemorySize(parsing: "4g")
        spec.removeOnStop = true
        _ = await drain(backend.createCluster(spec))
        try await backend.deleteCluster("dev")
        _ = await drain(backend.loadImage("app:1", intoCluster: nil, nodes: [], platform: nil))
        _ = await drain(backend.loadImage("app:1", intoCluster: "dev", nodes: [], platform: .arm64))
        #expect(runner.commands == [
            ["k8s", "--help"],
            ["k8s", "ls"],
            ["k8s", "create", "--name", "dev", "-c", "4", "-m", "4G", "--rm"],
            ["k8s", "delete", "--name", "dev"],
            ["k8s", "load-image", "--", "app:1"],
            ["k8s", "load-image", "--name", "dev", "--platform", "linux/arm64", "--", "app:1"],
        ])
    }

    @Test func unsupportedKubernetesOptionsFailWithoutRunning() async throws {
        let (backend, runner) = try makeBackend()
        var spec = ClusterSpec(name: "dev")
        spec.workers = 2
        let created = await drain(backend.createCluster(spec))
        #expect(created.error.map { if case BackendError.unsupported = $0 { true } else { false } } == true)
        let loaded = await drain(backend.loadImage("app:1", intoCluster: nil, nodes: ["n1"], platform: nil))
        #expect(loaded.error.map { if case BackendError.unsupported = $0 { true } else { false } } == true)
        #expect(runner.calls.isEmpty)
    }

    @Test func terminalCommands() throws {
        let (backend, _) = try makeBackend()
        #expect(backend.terminalCommand(for: .container(id: "web", command: ["sh"])).arguments == ["exec", "-it", "--", "web", "sh"])
        #expect(backend.terminalCommand(for: .machine(name: "dev")).arguments == ["machine", "run", "-n", "dev"])
    }
}
