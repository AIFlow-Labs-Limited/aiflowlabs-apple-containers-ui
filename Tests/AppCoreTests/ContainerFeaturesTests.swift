import ContainerKit
import ContainerKitMock
import Foundation
import Testing

@testable import AppCore

@MainActor
@Suite struct ContainerStatsHistoryTests {
    private func sample(
        _ id: String = "web", cpu: Int64, rx: Int64 = 0, tx: Int64 = 0, read: Int64 = 0,
        write: Int64 = 0, mem: Int64 = 100
    ) -> ContainerStats {
        ContainerStats(
            id: id, cpuUsageUsec: cpu, memoryUsageBytes: mem, memoryLimitBytes: 1000, networkRxBytes: rx,
            networkTxBytes: tx, blockReadBytes: read, blockWriteBytes: write, numProcesses: 3)
    }

    @Test func firstSamplePrimesCountersOnly() {
        let history = ContainerStatsHistory()
        let p = history.append(sample(cpu: 5_000_000, rx: 1_000), at: Date(timeIntervalSince1970: 0))
        #expect(p.cpuPercent == 0)
        #expect(p.networkRxPerSecond == 0)
        #expect(p.memoryBytes == 100)
        #expect(p.processes == 3)
        #expect(history.points(for: "web").count == 1)
    }

    @Test func ratesAreDerivedFromConsecutiveSamples() {
        let history = ContainerStatsHistory()
        let t0 = Date(timeIntervalSince1970: 1_000)
        history.append(sample(cpu: 0, rx: 0, tx: 0, read: 0, write: 0), at: t0)
        // 2 s later: 1 s of CPU time (50 %), 4 KB rx (2 KB/s), 1 KB tx, 8 KB read, 2 KB write.
        let p = history.append(
            sample(cpu: 1_000_000, rx: 4096, tx: 1024, read: 8192, write: 2048), at: t0.addingTimeInterval(2))
        #expect(abs(p.cpuPercent - 50) < 0.0001)
        #expect(p.networkRxPerSecond == 2048)
        #expect(p.networkTxPerSecond == 512)
        #expect(p.blockReadPerSecond == 4096)
        #expect(p.blockWritePerSecond == 1024)
        #expect(history.latest(for: "web") == p)
    }

    @Test func counterResetNeverGoesNegative() {
        let history = ContainerStatsHistory()
        let t0 = Date(timeIntervalSince1970: 0)
        history.append(sample(cpu: 9_000_000, rx: 50_000), at: t0)
        let p = history.append(sample(cpu: 100, rx: 10), at: t0.addingTimeInterval(2))
        #expect(p.cpuPercent == 0)
        #expect(p.networkRxPerSecond == 0)
    }

    @Test func evictsPointsOlderThanWindow() {
        let history = ContainerStatsHistory(window: 10)
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<20 { history.append(sample(cpu: Int64(i) * 1000), at: t0.addingTimeInterval(Double(i))) }
        let points = history.points(for: "web")
        #expect(points.count == 11)  // t = 9…19 inclusive
        #expect(points.first?.date == t0.addingTimeInterval(9))
    }

    @Test func seriesArePerContainerAndResettable() {
        let history = ContainerStatsHistory()
        history.append(sample("a", cpu: 0))
        history.append(sample("b", cpu: 0))
        history.reset("a")
        #expect(history.points(for: "a").isEmpty)
        #expect(history.points(for: "b").count == 1)
    }
}

@Suite struct LogRingBufferTests {
    @Test func dropsOldestBeyondCapacity() {
        var buffer = LogRingBuffer(capacity: 100)
        for i in 0..<250 { buffer.append(OutputLine("line \(i)")) }
        #expect(buffer.count == 100)
        #expect(buffer.lines.first?.text == "line 150")
        #expect(buffer.lines.last?.text == "line 249")
        #expect(buffer.totalAppended == 250)
        #expect(buffer.droppedCount == 150)
    }

    @Test func bulkAppendAndClear() {
        var buffer = LogRingBuffer(capacity: 20_000)
        buffer.append(contentsOf: (0..<25_000).map { OutputLine("l\($0)") })
        #expect(buffer.count == 20_000)
        #expect(buffer.lines.first?.text == "l5000")
        buffer.removeAll()
        #expect(buffer.isEmpty)
        #expect(buffer.droppedCount == 0)
    }

    @Test func searchIsCaseInsensitiveAndIndexed() {
        var buffer = LogRingBuffer(capacity: 10)
        buffer.append(contentsOf: ["GET /a 200", "error: boom", "GET /b 404", "ERROR again"].map { OutputLine($0) })
        #expect(buffer.matches("error") == [1, 3])
        #expect(buffer.matches("  ").isEmpty)
        #expect(buffer.text() == "GET /a 200\nerror: boom\nGET /b 404\nERROR again")
    }

    @Test func textWithTimestampsPrefixesEachLine() {
        var buffer = LogRingBuffer(capacity: 10)
        buffer.append(OutputLine("hello"))
        let text = buffer.text(timestamps: true)
        #expect(text.hasSuffix(" hello"))
        #expect(text.split(separator: " ").first?.split(separator: ":").count == 3)
    }
}

@Suite struct EnvironmentMaskingTests {
    @Test func parsesEntries() {
        let vars = EnvironmentVariable.parse(["PATH=/usr/bin", "EQ=a=b", "BARE", "EMPTY="])
        #expect(vars.map(\.key) == ["PATH", "EQ", "BARE", "EMPTY"])
        #expect(vars[1].value == "a=b")
        #expect(vars[2].value == nil)
        #expect(vars[3].value == "")
        #expect(vars.map(\.entry) == ["PATH=/usr/bin", "EQ=a=b", "BARE", "EMPTY="])
    }

    @Test func masksSensitiveKeys() {
        for key in ["POSTGRES_PASSWORD", "api_token", "AWS_SECRET_ACCESS_KEY", "SSH_KEY", "GITHUB_TOKEN"] {
            let v = EnvironmentVariable(key: key, value: "hunter2")
            #expect(v.isSensitive, "\(key) should be sensitive")
            #expect(v.displayValue(reveal: false) != "hunter2")
            #expect(!v.displayValue(reveal: false).contains("hunter2"))
            #expect(v.displayValue(reveal: true) == "hunter2")
        }
        let plain = EnvironmentVariable(key: "PYTHON_VERSION", value: "3.15.0")
        #expect(!plain.isSensitive)
        #expect(plain.displayValue(reveal: false) == "3.15.0")
    }

    @Test func dotEnvParsing() {
        let text = """
            # comment
            export A=1
            B = "two words"
            C='single'

            D
            E=x=y
            """
        let vars = DotEnv.parse(text)
        #expect(vars.map(\.entry) == ["A=1", "B=two words", "C=single", "D", "E=x=y"])
    }

    @Test func shellWords() {
        #expect(ShellWords.split("sleep 300") == ["sleep", "300"])
        #expect(ShellWords.split("sh -c 'echo hi && sleep 5'") == ["sh", "-c", "echo hi && sleep 5"])
        #expect(ShellWords.split(#"echo "a \"b\"" c\ d"#) == ["echo", #"a "b""#, "c d"])
        #expect(ShellWords.split("  ") == [])
        #expect(ShellWords.split("''") == [""])
        let words = ["sh", "-c", "echo 'hi' $HOME", ""]
        #expect(ShellWords.split(ShellWords.join(words)) == words)
    }
}

@Suite struct RunSpecRoundTripTests {
    /// Builds the container the mock backend would create for `spec` (same mapping as `MockBackend.createContainer`
    /// plus mounts/flags the mock ignores).
    private func container(from spec: RunSpec) -> Container {
        let desc = Descriptor(
            digest: "sha256:" + String(repeating: "cd", count: 32),
            mediaType: "application/vnd.oci.image.index.v1+json", size: 1)
        var mounts: [Container.Mount] = spec.mounts.map { m in
            switch m.kind {
            case .bind(let p):
                return .init(destination: m.target, source: p, options: m.readOnly ? ["ro"] : [], type: .bind)
            case .volume(let n):
                return .init(
                    destination: m.target, source: "/vol/\(n)", options: m.readOnly ? ["ro"] : [],
                    type: .volume(name: n, format: "ext4"))
            case .anonymous: return .init(destination: m.target, source: "", type: .volume(name: "anon", format: nil))
            }
        }
        mounts += spec.tmpfs.map { .init(destination: $0, source: "", type: .tmpfs(options: [:])) }
        let config = Container.Configuration(
            id: spec.name ?? "x", image: ImageReference(reference: spec.image, descriptor: desc), creationDate: .now,
            platform: spec.platform ?? .arm64,
            resources: .init(cpus: spec.cpus ?? 4, memoryInBytes: spec.memory?.bytes ?? (1 << 30)),
            initProcess: .init(
                executable: spec.command.first ?? "sh", arguments: Array(spec.command.dropFirst()),
                environment: spec.environment, workingDirectory: spec.workingDirectory ?? "/"),
            labels: spec.labels.merging(["com.apple.container.resource.anonymous": "1"]) { a, _ in a },
            mounts: mounts,
            networks: [
                .init(
                    network: spec.network ?? "default",
                    options: .init(
                        hostname: "x.test.", mac: spec.macAddress,
                        aliases: spec.networkAliases.isEmpty ? nil : spec.networkAliases))
            ],
            publishedPorts: spec.ports.map {
                .init(
                    hostAddress: $0.hostAddress ?? "0.0.0.0", hostPort: $0.hostPort, containerPort: $0.containerPort,
                    proto: $0.proto)
            },
            capAdd: spec.capAdd, capDrop: spec.capDrop, readOnly: spec.readOnly, ssh: spec.ssh, useInit: spec.useInit)
        return Container(id: spec.name ?? "x", configuration: config, status: .init(state: .running))
    }

    @Test func recreatesEquivalentSpec() {
        var spec = RunSpec(image: "docker.io/library/alpine:latest")
        spec.name = "cd-ui-test"
        spec.command = ["sleep", "300"]
        spec.environment = ["FOO=bar", "TOKEN=x"]
        spec.ports = [.init(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80)]
        spec.mounts = [
            .init(kind: .bind(hostPath: "/Users/me/src"), target: "/src", readOnly: true),
            .init(kind: .volume(name: "data"), target: "/data"),
        ]
        spec.tmpfs = ["/tmp"]
        spec.workingDirectory = "/src"
        spec.cpus = 2
        spec.memory = MemorySize(bytes: 512 << 20)
        spec.platform = .amd64
        spec.network = "backend"
        spec.networkAliases = ["api"]
        spec.labels = ["app": "demo"]
        spec.useInit = true
        spec.readOnly = true
        spec.ssh = true
        spec.capAdd = ["NET_ADMIN"]

        let rebuilt = RunSpec(recreating: container(from: spec))
        #expect(rebuilt == spec)
        #expect(rebuilt.cliArguments == spec.cliArguments)
        #expect(rebuilt.commandLineString.hasPrefix("container run -d --name cd-ui-test"))
    }

    @Test func subtractsImageDefaults() {
        var spec = RunSpec(image: "postgres:16")
        spec.name = "db"
        spec.command = ["docker-entrypoint.sh", "postgres"]
        spec.environment = ["PATH=/usr/bin", "POSTGRES_PASSWORD=pw"]
        spec.cpus = 4
        spec.memory = MemorySize(bytes: 1 << 30)
        let image = try! JSONDecoder().decode(
            Image.OCIConfig.RuntimeConfig.self,
            from: Data(
                #"""
                {"Entrypoint": ["docker-entrypoint.sh"], "Cmd": ["postgres"], "Env": ["PATH=/usr/bin"]}
                """#.utf8))
        let rebuilt = RunSpec(recreating: container(from: spec), imageConfig: image)
        #expect(rebuilt.command.isEmpty)
        #expect(rebuilt.environment == ["POSTGRES_PASSWORD=pw"])

        var custom = spec
        custom.command = ["docker-entrypoint.sh", "postgres", "-c", "fsync=off"]
        #expect(
            RunSpec(recreating: container(from: custom), imageConfig: image).command == ["postgres", "-c", "fsync=off"])
    }

    @Test func mockFixturesProduceRunnableCommands() async throws {
        let containers = try await MockBackend().listContainers(includeStopped: true)
        for c in containers {
            let spec = RunSpec(recreating: c)
            #expect(spec.issues.isEmpty, "\(c.id): \(spec.issues)")
            #expect(spec.cliArguments.contains(c.imageReference))
        }
    }

    @Test func validation() {
        var spec = RunSpec(image: "")
        spec.name = "-bad"
        spec.ports = [
            .init(hostPort: 8080, containerPort: 80), .init(hostPort: 8080, containerPort: 81),
            .init(hostPort: 70_000, containerPort: 1),
        ]
        spec.memory = MemorySize(bytes: 32 << 20)
        spec.mounts = [.init(kind: .anonymous, target: "data")]
        let issues = spec.issues
        #expect(issues.contains(.missingImage))
        #expect(issues.contains(.invalidName("-bad")))
        #expect(issues.contains(.duplicateHostPort(8080)))
        #expect(issues.contains(.portOutOfRange(70_000)))
        #expect(issues.contains(.memoryTooSmall(32 << 20)))
        #expect(issues.contains(.relativeMountTarget("data")))
        #expect(RunSpec.isValidName("cd-ui-test"))
        #expect(RunSpec.isValidName("a.b_c"))
        #expect(!RunSpec.isValidName("has space"))
    }
}
