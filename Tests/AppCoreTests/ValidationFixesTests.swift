import Foundation
import Testing
import ContainerKit
@testable import AppCore

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
