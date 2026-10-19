import Foundation
import Testing
import ContainerKit
import ContainerKitMock
@testable import AppCore

@MainActor
@Suite struct ResourceFeaturesTests {
    // MARK: Usage mapping

    @Test func imageInUseMatchesCanonicalReferences() async throws {
        let model = TestSupport.model()
        await model.containers.refresh()
        await model.images.refresh()
        let containers = model.containers.items
        // `image ls` reports the local build as `acdemo-api:latest`; the mock container uses docker.io/library/acdemo-api:latest.
        let api = try #require(model.images.items.first { $0.reference == "acdemo-api:latest" })
        #expect(ResourceUsage.containers(using: api, in: containers).map(\.id) == ["api"])
        let postgres = model.images.items.first { $0.reference == "docker.io/library/postgres:16-alpine" }!
        #expect(ResourceUsage.containers(using: postgres, in: containers).map(\.id) == ["db"])
        let unused = model.images.items.first { $0.reference == "docker.io/library/ros:jazzy-ros-core" }!
        #expect(ResourceUsage.containers(using: unused, in: containers).isEmpty)
    }

    @Test func canonicalReferenceNames() {
        #expect(ImageReferenceName.canonical("alpine") == "docker.io/library/alpine:latest")
        #expect(ImageReferenceName.canonical("alpine:3.22") == "docker.io/library/alpine:3.22")
        #expect(ImageReferenceName.canonical("you/app") == "docker.io/you/app:latest")
        #expect(ImageReferenceName.canonical("ghcr.io/x/y:1") == "ghcr.io/x/y:1")
        #expect(ImageReferenceName.canonical("localhost:5000/app") == "localhost:5000/app:latest")
        #expect(ImageReferenceName.registry(of: "redis:7") == "docker.io")
        #expect(ImageReferenceName.registry(of: "ghcr.io/a/b") == "ghcr.io")
        #expect(ImageReferenceName.same("redis:7", "docker.io/library/redis:7"))
    }

    @Test func volumeInUseMapping() async {
        let model = TestSupport.model()
        await model.containers.refresh()
        await model.volumes.refresh()
        let probevol = model.volumes.items.first { $0.name == "probevol" }!
        #expect(ResourceUsage.containers(mounting: probevol, in: model.containers.items).map(\.id) == ["probe"])
        await model.volumes.create(name: "fresh")
        let fresh = model.volumes.items.first { $0.name == "fresh" }!
        #expect(ResourceUsage.containers(mounting: fresh, in: model.containers.items).isEmpty)
    }

    @Test func networkAttachmentMapping() async {
        let model = TestSupport.model()
        await model.containers.refresh()
        await model.networks.refresh()
        let def = model.networks.items.first { $0.name == "default" }!
        let attached = ResourceUsage.containers(attachedTo: def, in: model.containers.items).map(\.id)
        #expect(attached.contains("api") && attached.contains("db"))
        let custom = Network(id: "backend", configuration: .init(name: "backend", creationDate: .now))
        let desc = Descriptor(digest: "sha256:00", mediaType: "", size: 0)
        let onBackend = Container(id: "w", configuration: .init(id: "w", image: ImageReference(reference: "nginx", descriptor: desc),
                                                                creationDate: .now, initProcess: .init(executable: "nginx"),
                                                                networks: [.init(network: "backend")]),
                                  status: .init(state: .stopped))
        // Stopped containers have no runtime networks; the configured attachment counts.
        #expect(ResourceUsage.containers(attachedTo: custom, in: [onBackend]).map(\.id) == ["w"])
        #expect(ResourceUsage.containers(attachedTo: def, in: [onBackend]).isEmpty)
    }

    // MARK: Validators

    @Test func nameValidator() {
        #expect(ResourceValidator.resourceName("pgdata") == nil)
        #expect(ResourceValidator.resourceName("cd-ui-test_vol.1") == nil)
        #expect(ResourceValidator.resourceName("") != nil)
        #expect(ResourceValidator.resourceName("-bad") != nil)
        #expect(ResourceValidator.resourceName("has space") != nil)
        #expect(ResourceValidator.resourceName(String(repeating: "a", count: 64)) != nil)
    }

    @Test func cidrValidators() {
        #expect(ResourceValidator.ipv4CIDR("192.168.70.0/24") == nil)
        #expect(ResourceValidator.ipv4CIDR("10.0.0.0/8") == nil)
        #expect(ResourceValidator.ipv4CIDR("192.168.70.0") != nil)
        #expect(ResourceValidator.ipv4CIDR("192.168.300.0/24") != nil)
        #expect(ResourceValidator.ipv4CIDR("192.168.1.0/33") != nil)
        #expect(ResourceValidator.ipv4CIDR("1.2.3/24") != nil)
        #expect(ResourceValidator.ipv6CIDR("fd00:70::/64") == nil)
        #expect(ResourceValidator.ipv6CIDR("fd00:70::") != nil)
        #expect(ResourceValidator.ipv6CIDR("fd00::zz/64") != nil)
        #expect(ResourceValidator.ipv6CIDR("fd00::/129") != nil)
    }

    @Test func referenceAndTagValidators() {
        for ok in ["alpine", "alpine:3.22", "cd-ui-test:1", "ghcr.io/you/app:1.0", "localhost:5000/a/b:c",
                   "redis@sha256:" + String(repeating: "a", count: 64)] {
            #expect(ResourceValidator.imageReference(ok) == nil, "\(ok)")
        }
        for bad in ["", "Alpine", "alpine:", "a b", "app:-x", "ghcr.io//x", "x@sha256:12"] {
            #expect(ResourceValidator.imageReference(bad) != nil, "\(bad)")
        }
        #expect(ResourceValidator.tag("1.0_rc-1") == nil)
        #expect(ResourceValidator.tag(".bad") != nil)
    }

    @Test func rowValidators() {
        #expect(ResourceValidator.keyValue("A=1") == nil)
        #expect(ResourceValidator.keyValue("A") != nil)
        #expect(ResourceValidator.keyValue("A", allowBareKey: true) == nil)
        #expect(ResourceValidator.keyValue("=1") != nil)
        #expect(ResourceValidator.buildSecret("id=npm,env=NPM_TOKEN") == nil)
        #expect(ResourceValidator.buildSecret("id=key,src=/tmp/k") == nil)
        #expect(ResourceValidator.buildSecret("env=X") != nil)
        #expect(ResourceValidator.buildSecret("id=a,env=X,src=y") != nil)
        #expect(ResourceValidator.labels(from: ["a=1", "b=", "bad", " c = 3"]) == ["a": "1", "b": "", "c ": " 3"])
    }

    @Test func environmentMasking() {
        #expect(EnvironmentMasking.masked("POSTGRES_PASSWORD=hunter2") == "POSTGRES_PASSWORD=••••••")
        #expect(EnvironmentMasking.masked("GITHUB_TOKEN=abc") == "GITHUB_TOKEN=••••••")
        #expect(EnvironmentMasking.masked("PATH=/usr/bin") == "PATH=/usr/bin")
        #expect(EnvironmentMasking.split("LANG").key == "LANG")
    }

    // MARK: Builds

    @Test func buildSpecPreviewString() {
        var spec = BuildSpec(contextDirectory: "/Users/me/my app", tag: "app:dev")
        spec.dockerfile = "Containerfile"
        spec.platforms = [.arm64, .amd64]
        spec.buildArgs = ["VERSION=1.2"]
        spec.target = "runtime"
        spec.noCache = true
        spec.secrets = ["id=npm,env=NPM_TOKEN"]
        spec.forwardSSH = true
        #expect(spec.commandPreview == "container build -t app:dev --progress plain -f Containerfile --platform linux/arm64 "
                + "--platform linux/amd64 --build-arg VERSION=1.2 --target runtime --no-cache --secret id=npm,env=NPM_TOKEN "
                + "--ssh default '/Users/me/my app'")
        #expect(spec.commandPreview.hasSuffix(spec.cliArguments.last.map { "'\($0)'" } ?? ""))
    }

    @Test func buildContextInspection() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cd-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "FROM python:3.11 AS base\nRUN true\nFROM base as runtime\nCOPY . .\n".write(to: dir.appending(path: "Containerfile"), atomically: true, encoding: .utf8)
        try "FROM alpine\n".write(to: dir.appending(path: "Dockerfile"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appending(path: "dev.Dockerfile"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "node_modules\n".write(to: dir.appending(path: "Dockerfile.dockerignore"), atomically: true, encoding: .utf8)
        #expect(BuildContextInspector.dockerfiles(in: dir) == ["Dockerfile", "Containerfile", "dev.Dockerfile"])
        #expect(BuildContextInspector.stages(dockerfile: "Containerfile", in: dir) == ["base", "runtime"])
        #expect(BuildContextInspector.stages(dockerfile: "Dockerfile", in: dir).isEmpty)
    }

    /// A Finder-launched app has cwd `/`, and the CLI resolves `-f` / `src=` against its cwd: both must be absolute.
    @Test func buildSpecPathsAreAbsolute() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        var spec = BuildSpec(contextDirectory: "~/src/app", tag: "app:dev")
        spec.dockerfile = "Dockerfile.dev"
        spec.secrets = ["id=key,src=~/.ssh/id_ed25519", "id=cfg,src=config/secret.txt", "id=npm,env=NPM_TOKEN"]
        let resolved = spec.resolvingPaths()
        let args = resolved.cliArguments
        let f = try #require(args.firstIndex(of: "-f"))
        let context = (home as NSString).appendingPathComponent("src/app")
        #expect(args[f + 1] == context + "/Dockerfile.dev")
        #expect(args[f + 1].hasPrefix("/"))
        #expect(args.last == context)
        #expect(resolved.secrets == ["id=key,src=" + (home as NSString).appendingPathComponent(".ssh/id_ed25519"),
                                     "id=cfg,src=\(context)/config/secret.txt", "id=npm,env=NPM_TOKEN"])
        // Absolute paths are kept (normalized), and an already-resolved spec is unchanged.
        var abs = BuildSpec(contextDirectory: "/work/app/", tag: "t")
        abs.dockerfile = "/work/other/../app/ci.Dockerfile"
        #expect(abs.resolvingPaths().dockerfile == "/work/app/ci.Dockerfile")
        #expect(resolved.resolvingPaths() == resolved)
        #expect(BuildContextInspector.stages(dockerfile: "Dockerfile.dev", in: URL(filePath: "/nonexistent")).isEmpty)
    }

    // MARK: Prune candidates

    /// Prune runs unfiltered on the engine, so the confirmation must list every unused resource, not just the
    /// rows the search shows.
    @Test func pruneCandidatesIgnoreSearch() async {
        let model = TestSupport.model()
        await model.containers.refresh()
        await model.volumes.refresh()
        await model.networks.refresh()
        _ = await model.volumes.create(name: "zz-unused-a")
        _ = await model.volumes.create(name: "zz-unused-b")
        _ = await model.networks.create(name: "zz-net")
        let containers = model.containers.items
        let allVolumes = PruneCandidates.volumes(model.volumes.items, containers: containers).map(\.name)
        let allNetworks = PruneCandidates.networks(model.networks.items, containers: containers).map(\.name)
        model.volumes.searchText = "zz-unused-a"
        model.networks.searchText = "nothing-matches"
        #expect(model.volumes.filtered.count == 1)
        #expect(model.networks.filtered.isEmpty)
        #expect(PruneCandidates.volumes(model.volumes.items, containers: containers).map(\.name) == allVolumes)
        #expect(PruneCandidates.networks(model.networks.items, containers: containers).map(\.name) == allNetworks)
        #expect(allVolumes.contains("zz-unused-a") && allVolumes.contains("zz-unused-b") && !allVolumes.contains("probevol"))
        #expect(allNetworks.contains("zz-net") && !allNetworks.contains("default"))
        #expect(PruneCandidates.hiddenCount(candidates: allVolumes, visible: model.volumes.filtered.map(\.name)) == allVolumes.count - 1)
    }

    @Test func pruneOutcomeIsADiff() {
        #expect(PruneCandidates.removed(before: ["a", "b", "c"], after: ["b"]) == ["a", "c"])
        #expect(PruneCandidates.removed(before: ["a"], after: ["a", "new"]).isEmpty)
    }

    // MARK: Run hand-off

    @Test func runRequestsHandoff() {
        let model = TestSupport.model()
        #expect(model.runRequests.pending == nil)
        model.runRequests.request(image: "docker.io/library/alpine:3.22")
        model.navigation.open(.containers)
        #expect(model.navigation.section == .containers)
        #expect(model.runRequests.pending?.image == "docker.io/library/alpine:3.22")
        let spec = model.runRequests.consume()
        #expect(spec?.image == "docker.io/library/alpine:3.22")
        #expect(model.runRequests.pending == nil)
        #expect(model.runRequests.consume() == nil)
    }

    @Test func recentValuesDeduplicateAndTrim() {
        let suite = "cd-recents-\(UUID().uuidString)"
        let recents = RecentValues(key: "k", limit: 3, suiteName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        for v in ["a", "b", "c", "a", "d", " "] { recents.add(v) }
        #expect(recents.values == ["d", "a", "c"])
    }

    @Test func layerHistoryShortening() {
        #expect(LayerHistoryText.shorten("/bin/sh -c #(nop)  CMD [\"python3\"]") == "CMD [\"python3\"]")
        #expect(LayerHistoryText.shorten("RUN /bin/sh -c apk add  --no-cache curl # buildkit") == "RUN apk add --no-cache curl")
        #expect(LayerHistoryText.shorten(String(repeating: "x", count: 300)).count == 140)
    }
}
