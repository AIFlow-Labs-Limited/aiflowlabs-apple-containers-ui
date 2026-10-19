import Foundation
import Testing
import ContainerKit
@testable import AppCore
@testable import DesignSystem

@Suite struct ValidationFixesTests {
    @Test func buildSecretsMatchTheCLI() {
        #expect(ResourceValidator.buildSecret("id=npm,env=NPM_TOKEN") == nil)
        #expect(ResourceValidator.buildSecret("id=key,src=~/key") == nil)
        #expect(ResourceValidator.buildSecret("id=only") == nil)
        #expect(ResourceValidator.buildSecret("src=/k,id=key") == "Put id=NAME first.")
        #expect(ResourceValidator.buildSecret("id=k,type=file,src=/k")?.contains("type=") == true)
        #expect(ResourceValidator.buildSecret("id=k,mode=0400") == "Unknown field “mode”.")
        #expect(ResourceValidator.buildSecret("id=k,env=") != nil)
        #expect(ResourceValidator.buildSecret("id=,env=X") != nil)
    }

    @Test func buildSecretSourcesAreResolved() {
        #expect(ResourceValidator.resolvedBuildSecret("id=k,src=~/key", contextDirectory: "/ctx", home: "/Users/me")
                == "id=k,src=/Users/me/key")
        #expect(ResourceValidator.resolvedBuildSecret("id=k,src=secrets/k.txt", contextDirectory: "/ctx", home: "/h")
                == "id=k,src=/ctx/secrets/k.txt")
        #expect(ResourceValidator.resolvedBuildSecret("id=k,src=/abs", contextDirectory: "/ctx") == "id=k,src=/abs")
        #expect(ResourceValidator.resolvedBuildSecret("id=k,env=TOKEN", contextDirectory: "/ctx") == "id=k,env=TOKEN")
    }

    @Test func ipv4CIDRRules() {
        #expect(ResourceValidator.ipv4CIDR("192.168.70.0/24") == nil)
        #expect(ResourceValidator.ipv4CIDR("10.0.0.0/8") == nil)
        #expect(ResourceValidator.ipv4CIDR("10.1.2.0/30") == nil)
        #expect(ResourceValidator.ipv4CIDR("0.0.0.0/0") != nil)          // prefix out of /8–/30
        #expect(ResourceValidator.ipv4CIDR("10.0.0.0/31") != nil)
        #expect(ResourceValidator.ipv4CIDR("10.0.0.0/+8") != nil)
        #expect(ResourceValidator.ipv4CIDR("192.168.70.5/24") == "Host bits are set; the network address is 192.168.70.0/24.")
        #expect(ResourceValidator.ipv4CIDRWarning("192.168.64.0/20")?.contains("default network") == true)
        #expect(ResourceValidator.ipv4CIDRWarning("192.168.70.0/24") == nil)
        #expect(ResourceValidator.ipv4CIDRWarning("10.0.1.0/24", existing: ["10.0.0.0/16"]) == "Overlaps the existing subnet 10.0.0.0/16.")
        #expect(ResourceValidator.ipv6CIDR("fd00::/+64") != nil)
    }

    @Test func referencesAndNames() {
        #expect(ResourceValidator.imageReference("[::1]:5000/x") == nil)
        #expect(ResourceValidator.imageReference("[::1]:5000/x:1") == nil)
        #expect(ImageReferenceName.canonical("docker.io/nginx") == ImageReferenceName.canonical("nginx"))
        #expect(ImageReferenceName.canonical("index.docker.io/library/nginx:1") == "docker.io/library/nginx:1")
        #expect(ImageReferenceName.canonical("[::1]:5000/x") == "[::1]:5000/x:latest")
        #expect(ImageReferenceName.same("docker.io/you/app", "you/app:latest"))
        #expect(RunSpec.isValidName("cd-ui-test") && !RunSpec.isValidName(" x"))
        #expect(ResourceValidator.resourceName("a.b", allowDots: false) != nil)
        #expect(ResourceValidator.resourceName(String(repeating: "a", count: 100), maxLength: nil) == nil)
    }

    @Test func labelsTrimKeysAndValues() {
        #expect(ResourceValidator.labels(from: [" app = web ", "=x", "k=v=w"]) == ["app": "web", "k": "v=w"])
    }

    @Test func digestPinnedContainerUsesImage() {
        let digest = "sha256:" + String(repeating: "ab", count: 32)
        let image = Image(id: digest, configuration: .init(name: "docker.io/library/nginx:1.27", creationDate: .now,
                                                           descriptor: Descriptor(digest: digest, mediaType: "x", size: 1)),
                          variants: [])
        func container(_ ref: String, digest d: String) -> Container {
            Container(id: ref, configuration: .init(id: ref, image: ImageReference(reference: ref, descriptor: Descriptor(digest: d, mediaType: "x", size: 1)),
                                                    creationDate: .now, initProcess: .init(executable: "nginx")))
        }
        let pinned = container("nginx@\(digest)", digest: digest)
        let byName = container("nginx:1.27", digest: "sha256:00")
        let other = container("nginx:1.25", digest: digest)          // same digest, different tag, not pinned
        let users = ResourceUsage.containers(using: image, in: [pinned, byName, other]).map(\.id)
        #expect(users == [pinned.id, byName.id])
    }
}

@MainActor
@Suite struct BuildHistoryFileTests {
    @Test func corruptHistoryIsMovedAsideAndReported() throws {
        let url = TestSupport.historyURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        let store = BuildsStore(backend: UnavailableBackend(searchedPaths: []), tasks: TaskCenter(), gate: PollingGate(), historyURL: url)
        #expect(store.history.isEmpty)
        #expect(store.lastError?.errorDescription?.contains(".bak") == true)
        let backup = url.appendingPathExtension("bak")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")
    }

    @Test func legacyArrayAndMissingFieldsStillLoad() throws {
        let url = TestSupport.historyURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"tag":"app:1","status":"succeeded","startedAt":"2026-01-01T00:00:00Z"},{"tag":"x","status":"weird"}]"#.utf8).write(to: url)
        guard case .success(let records) = BuildsStore.loadHistory(from: url) else { Issue.record("expected success"); return }
        #expect(records.map(\.tag) == ["app:1", "x"])
        #expect(records[0].status == .succeeded && records[0].log.isEmpty && records[0].platforms.isEmpty)
        #expect(records[1].status == .failed)
    }

    @Test func savedFileIsVersioned() async throws {
        let model = TestSupport.model()
        let task = model.builds.build(BuildSpec(contextDirectory: "/tmp", tag: "v:1"))
        await task.wait()
        try await Task.sleep(for: .milliseconds(50))
        let url = try #require(Mirror(reflecting: model.builds).descendant("historyURL") as? URL)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains("\"version\" : 1"))
        guard case .success(let records) = BuildsStore.loadHistory(from: url) else { Issue.record("reload failed"); return }
        #expect(records.first?.tag == "v:1")
    }
}

@Suite struct RunSpecFixesTests {
    @Test func imageCannotLookLikeAFlag() {
        #expect(RunSpec(image: "--privileged").issues.contains(.invalidImage("--privileged")))
        #expect(RunSpec(image: "alpine latest").issues.contains(.invalidImage("alpine latest")))
        #expect(RunSpec(image: " alpine ").issues.isEmpty)
    }

    @Test func wildcardHostPortsCollide() {
        func spec(_ hosts: [String?]) -> RunSpec {
            var s = RunSpec(image: "nginx")
            s.ports = hosts.map { RunSpec.PortMapping(hostAddress: $0, hostPort: 80, containerPort: 80) }
            return s
        }
        #expect(spec([nil, "0.0.0.0"]).issues.contains(.duplicateHostPort(80)))
        #expect(spec(["*", "0.0.0.0"]).issues.contains(.duplicateHostPort(80)))
        #expect(spec(["127.0.0.1", nil]).issues.contains(.duplicateHostPort(80)))
        #expect(spec(["127.0.0.1", "192.168.1.2"]).issues.isEmpty)
        var udp = spec([nil])
        udp.ports.append(.init(hostPort: 80, containerPort: 80, proto: "udp"))
        #expect(udp.issues.isEmpty)
    }

    @Test func bindSourcesExpandTilde() {
        var s = RunSpec(image: "alpine")
        s.mounts = [.init(kind: .bind(hostPath: "~/project"), target: "/src"), .init(kind: .bind(hostPath: "rel/dir"), target: "/x")]
        #expect(s.issues == [.relativeMountSource("rel/dir")])
        let run = s.normalizedForRun(home: "/Users/me")
        #expect(run.mounts[0].kind == .bind(hostPath: "/Users/me/project"))
    }

    @Test func recreateKeepsEveryNetworkAndDNSDomain() {
        let desc = Descriptor(digest: "sha256:00", mediaType: "x", size: 1)
        let c = Container(id: "web", configuration: .init(
            id: "web", image: ImageReference(reference: "nginx", descriptor: desc), creationDate: .now,
            initProcess: .init(executable: "nginx"),
            networks: [.init(network: "front"), .init(network: "back", options: .init(mac: "02:00:00:00:00:01", aliases: ["db"]))],
            dns: .init(domain: "test")))
        let spec = RunSpec(recreating: c)
        #expect(spec.network == "front")
        #expect(spec.dnsDomain == "test")
        #expect(spec.extraArguments == ["--network", "back,mac=02:00:00:00:00:01,alias=db"])
    }
}

@MainActor
@Suite struct MiscFixesTests {
    @Test func relativeDateHonoursNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let text = RelativeDate.format(now.addingTimeInterval(-7_200), relativeTo: now)
        #expect(text.contains("2") && text.contains("hour"))
        #expect(RelativeDate.format(now, relativeTo: now) == "just now")
    }

    @Test func percentIsLocalized() {
        #expect(Percent.format(12.34, locale: Locale(identifier: "en_US")) == "12.3%")
        #expect(Percent.format(12.34, locale: Locale(identifier: "fr_FR")).contains("12,3"))
    }

    @Test func jsonKeyPathsAreUnambiguous() {
        #expect(JSONKeyPath.component(forKey: "labels") == ".labels")
        #expect(JSONKeyPath.component(forKey: "com.example.role") == #"["com.example.role"]"#)
        #expect(JSONKeyPath.component(forKey: "[0]") == #"["[0]"]"#)
        let value: JSONValue = .object(["a.b": .object(["c": .array([.number(1)])])])
        let root = JSONTreeIndex().root(for: value, name: "root")
        #expect(root.children?.first?.path == #"$["a.b"]"#)
        #expect(root.children?.first?.children?.first?.children?.first?.path == #"$["a.b"].c[0]"#)
    }

    @Test func statsHistoryEvictsAndDropsStaleBaseline() {
        let h = ContainerStatsHistory(window: 60, maxSampleGap: 30)
        let t0 = Date(timeIntervalSince1970: 0)
        func sample(_ id: String, cpu: Int64) -> ContainerStats {
            ContainerStats(id: id, cpuUsageUsec: cpu, memoryUsageBytes: 1, memoryLimitBytes: 2)
        }
        h.append(sample("a", cpu: 0), at: t0)
        h.append(sample("b", cpu: 0), at: t0)
        let late = h.append(sample("a", cpu: 50_000_000), at: t0.addingTimeInterval(120))   // gap > 30 s
        #expect(late.cpuPercent == 0)                                                      // re-primed, no bogus rate
        h.retain(only: ["a"], now: t0.addingTimeInterval(120))
        #expect(h.points(for: "b").isEmpty)
        #expect(h.points(for: "a").count == 1)                                             // t0 point aged out
    }

    @Test func launchAtLoginMirrorsSystemStatus() {
        let s = SettingsStore(defaults: TestSupport.defaults(), loginItemStatus: { .requiresApproval })
        #expect(s.launchAtLogin)
        #expect(s.launchAtLoginRequiresApproval)
        #expect(s.launchAtLoginError?.contains("Login Items") == true)
        let off = SettingsStore(defaults: TestSupport.defaults(), loginItemStatus: { .notRegistered })
        #expect(!off.launchAtLogin)
    }
}
