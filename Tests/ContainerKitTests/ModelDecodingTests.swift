import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

@Suite("CLI 1.5.0 fixture decoding")
struct ModelDecodingTests {
    @Test func containers() throws {
        let list = try Fixtures.containers()
        let probe = try #require(list.first { $0.id == "probe" })
        #expect(probe.isRunning)
        #expect(probe.primaryIPv4 == "192.168.64.31")
        #expect(probe.hostname == "probe.test.")
        #expect(probe.configuration.publishedPorts.first?.display == "127.0.0.1:18099->8000/tcp")
        #expect(probe.configuration.mounts.first?.type.volumeName == "probevol")
        #expect(probe.commandLine == "python3 -m http.server 8000")
        #expect(probe.configuration.resources.memoryInBytes == 536_870_912)
        #expect(!probe.isSystemManaged)
    }

    @Test func builderIsSystemManaged() throws {
        let builder = try #require(try Fixtures.builder().first)
        #expect(builder.isBuilder)
        #expect(builder.isSystemManaged)
    }

    @Test func images() throws {
        let images = try Fixtures.images()
        #expect(images.count >= 10)
        let api = try #require(images.first { $0.reference == "acdemo-api:latest" })
        #expect(api.repository == "acdemo-api")
        #expect(api.tag == "latest")
        #expect(!api.isMultiArch)
        #expect(api.variants.first?.config?.config?.cmd?.first == "uvicorn")
        let smoke = try #require(images.first { $0.reference == "local/anima-smoke:latest" })
        #expect(smoke.isMultiArch)
        #expect(Set(smoke.platforms.map(\.architecture)) == ["arm64", "amd64"])
        let python = try #require(images.first { $0.reference == "docker.io/library/python:alpine" })
        #expect(python.repository == "python")
    }

    @Test func imageInspectHasHistory() throws {
        let images = try Fixtures.decode([Image].self, "image-inspect.json")
        let image = try #require(images.first)
        #expect(image.variants.first?.config?.rootfs?.diffIDs.isEmpty == false)
    }

    @Test func volumesNetworksStats() throws {
        let vol = try #require(try Fixtures.volumes().first)
        #expect(vol.name == "probevol")
        #expect(vol.configuration.sizeInBytes == 549_755_813_888)
        let net = try #require(try Fixtures.networks().first)
        #expect(net.isBuiltin)
        #expect(net.status?.ipv4Subnet == "192.168.64.0/24")
        let stats = try Fixtures.stats()
        #expect(stats.contains { $0.id == "probe" && $0.numProcesses == 1 })
    }

    @Test func cpuPercent() {
        let a = ContainerStats(id: "x", cpuUsageUsec: 1_000_000, memoryUsageBytes: 1, memoryLimitBytes: 2)
        let b = ContainerStats(id: "x", cpuUsageUsec: 2_000_000, memoryUsageBytes: 1, memoryLimitBytes: 2)
        #expect(ContainerStats.cpuPercent(previous: a, current: b, interval: 2) == 50)
    }

    @Test func system() throws {
        let status = try Fixtures.systemStatus()
        #expect(status.isRunning)
        #expect(status.server?.version == "1.5.0")
        #expect(status.host?.cpus == 18)
        let props = try Fixtures.systemProperties()
        #expect(props.dns?.domain == "test")
        #expect(props.container?.cpus == 4)
        let df = try Fixtures.diskUsage()
        #expect(df.images.total == 13)
    }

    @Test func machines() throws {
        let m = try #require(try Fixtures.machines().first)
        #expect(m.id == "probe-m")
        #expect(m.isDefault)
        #expect(m.status == .stopped)
        #expect(m.userSetup == nil)  // only `machine inspect` includes userSetup
    }

    @Test func dates() {
        #expect(CLIJSON.parseDate("2026-10-17T19:08:25Z") != nil)
        #expect(CLIJSON.parseDate("2026-10-17T18:58:22.245285014Z") != nil)
        #expect(CLIJSON.parseDate("2026-10-17T18:58:22.2Z") != nil)
        #expect(CLIJSON.parseDate("nope") == nil)
    }

    @Test func memorySize() {
        #expect(MemorySize(parsing: "1g")?.bytes == 1 << 30)
        #expect(MemorySize(parsing: "2048mb")?.bytes == 2 << 30)
        #expect(MemorySize(parsing: "512M")?.cliArgument == "512M")
        #expect(MemorySize(parsing: "bogus") == nil)
    }

    @Test func memorySizeRejectsOutOfRangeAndZero() {
        #expect(MemorySize(parsing: "9999999t") == nil)
        #expect(MemorySize(parsing: String(repeating: "9", count: 400)) == nil)
        #expect(MemorySize(parsing: String(repeating: "9", count: 400) + "g") == nil)
        #expect(MemorySize(parsing: "0") == nil)
        #expect(MemorySize(parsing: "0g") == nil)
        #expect(MemorySize(parsing: "-1g") == nil)
        #expect(MemorySize(parsing: ".") == nil)
        #expect(MemorySize(parsing: "8388607t") != nil)  // just under 2^63 bytes
        #expect(MemorySize(parsing: "8388608t") == nil)  // exactly 2^63 bytes
    }

    @Test func memorySizeCLIArgumentIsWholeMiB() {
        #expect(MemorySize(parsing: "1.5g")?.cliArgument == "1536M")
        #expect(MemorySize(parsing: ".5g")?.cliArgument == "512M")
        #expect(MemorySize(parsing: "1.1m")?.cliArgument == "1M")
        #expect(MemorySize(parsing: "1.6m")?.cliArgument == "2M")
        #expect(MemorySize(parsing: "4g")?.cliArgument == "4G")
        #expect(MemorySize(parsing: "2048m")?.cliArgument == "2G")
        #expect(MemorySize(parsing: "1k")?.cliArgument == "1M")
        #expect(MemorySize(parsing: "1.1m")?.cliArgumentBytes == "1153434")
        #expect(MemorySize(parsing: "10g")?.cliArgumentBytes == "10737418240")
    }

    @Test func runSpecArguments() {
        var spec = RunSpec(image: "postgres:16")
        spec.name = "db"
        spec.memory = MemorySize(parsing: "2g")
        spec.environment = ["POSTGRES_PASSWORD=x"]
        spec.ports = [.init(hostAddress: "127.0.0.1", hostPort: 5432, containerPort: 5432)]
        spec.mounts = [.init(kind: .volume(name: "pgdata"), target: "/var/lib/postgresql/data")]
        #expect(
            spec.cliArguments == [
                "-d", "--name", "db", "-e", "POSTGRES_PASSWORD=x", "-p", "127.0.0.1:5432:5432/tcp", "-v",
                "pgdata:/var/lib/postgresql/data", "-m", "2G", "postgres:16",
            ])
    }

    @Test func mockBackendMutates() async throws {
        let backend = MockBackend()
        await backend.setLatency(.zero)
        let before = try await backend.listContainers(includeStopped: true).count
        var spec = RunSpec(image: "alpine")
        spec.name = "t1"
        for try await _ in backend.runContainer(spec) {}
        #expect(try await backend.listContainers(includeStopped: true).count == before + 1)
        try await backend.stopContainer("t1", timeoutSeconds: nil, signal: nil)
        #expect(try await backend.inspectContainer("t1").state == .stopped)
        try await backend.deleteContainer("t1", force: false)
        await #expect(throws: BackendError.self) { try await backend.inspectContainer("t1") }
    }
}

extension MockBackend {
    func setLatency(_ d: Duration) { latency = d }
}
