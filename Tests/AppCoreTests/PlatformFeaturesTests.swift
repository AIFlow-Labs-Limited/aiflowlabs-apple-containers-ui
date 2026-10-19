import Foundation
import Testing
import ContainerKit
import ContainerKitMock
@testable import AppCore

@Suite struct PlatformFeaturesTests {
    // MARK: Machines

    @Test(arguments: ["dev", "my-box", "box_2", "A1"])
    func validMachineNames(_ name: String) {
        #expect(MachineNameRule.validate(name) == nil)
    }

    @Test(arguments: ["", "dev.local", "-dev", "_x", "has space", "naïve", String(repeating: "a", count: 64)])
    func invalidMachineNames(_ name: String) {
        #expect(MachineNameRule.validate(name) != nil)
    }

    @Test func machineNameDotsGetSpecificMessage() {
        #expect(MachineNameRule.validate("a.b")?.contains("Dots") == true)
    }

    @Test func machineFormDefaultsFromHost() {
        let host = HostResources(cpus: 12, memoryBytes: 64 << 30)
        let form = MachineForm(host: host)
        #expect(form.memoryGB == 32)
        #expect(form.cpus == 4)
        #expect(form.image == "ghcr.io/linuxcontainers/alpine:3.20")
        #expect(form.isValid)
    }

    @Test func machineFormPreviewMatchesSpec() {
        var form = MachineForm(host: HostResources(cpus: 8, memoryBytes: 16 << 30))
        form.name = "cd-ui-test"
        form.cpus = 2
        form.memoryGB = 2
        form.setDefault = true
        #expect(form.previewCommand() ==
            "container machine create --name cd-ui-test --cpus 2 --memory 2G --home-mount rw --set-default ghcr.io/linuxcontainers/alpine:3.20")
        #expect(form.previewCommand() == CommandLine(executable: "container",
                                                     arguments: ["machine", "create"] + form.spec.cliArguments).display)
    }

    @Test func machineFormBootAndVirtualization() {
        var form = MachineForm(host: HostResources(cpus: 8, memoryBytes: 16 << 30))
        form.bootNow = false
        form.homeMount = .none
        #expect(form.spec.noBoot)
        form.virtualization = true
        #expect(form.kernelError != nil)
        #expect(!form.isValid)
        form.kernelPath = "/k/vmlinux"
        #expect(form.isValid)
        #expect(form.previewCommand().hasSuffix("--home-mount none --no-boot --virtualization --kernel /k/vmlinux ghcr.io/linuxcontainers/alpine:3.20"))
        #expect(!form.previewCommand().contains("--user"))
    }

    @Test func machineFormRejectsDuplicateNames() {
        var form = MachineForm(host: HostResources(cpus: 4, memoryBytes: 8 << 30), existingNames: ["dev", "Box"])
        #expect(form.nameError?.contains("already exists") == true)
        #expect(!form.isValid)
        form.name = "box"
        #expect(form.nameError != nil)
        form.name = "dev-2"
        #expect(form.nameError == nil && form.isValid)
    }

    @Test func machineFormValidatesImage() {
        var form = MachineForm(host: HostResources(cpus: 4, memoryBytes: 8 << 30))
        form.image = "  "
        #expect(form.imageError != nil && !form.isValid)
        form.image = "Not A Ref!"
        #expect(form.imageError != nil && !form.isValid)
        form.image = "docker.io/library/alpine:3.22"
        #expect(form.imageIsKnownBroken && !form.isValid)
        form.image = MachineImageOption.verified.reference
        #expect(form.imageError == nil && form.isValid)
        form.image = "registry.example.com/team/box:1"
        #expect(form.imageError == nil && form.isValid)
    }

    @Test(arguments: ["alpine", "alpine:latest", "alpine:3.22", "Alpine:3.20", "docker.io/alpine", "docker.io/alpine:3.19",
                      "docker.io/library/alpine", "docker.io/library/alpine:latest", "docker.io/library/alpine:3.20",
                      "index.docker.io/library/alpine:3.18", "alpine@sha256:abc", " alpine:edge "])
    func knownBrokenAlpineSpellings(_ ref: String) {
        #expect(MachineImageOption.knownBroken(ref))
    }

    @Test(arguments: ["ghcr.io/linuxcontainers/alpine:3.20", "alpine-sdk:1", "you/alpine:1", "docker.io/you/alpine",
                      "ubuntu:24.04", "quay.io/alpine/alpine:3"])
    func notKnownBroken(_ ref: String) {
        #expect(!MachineImageOption.knownBroken(ref))
    }

    @Test func curatedImages() {
        #expect(MachineImageOption.curated.first?.support == .verified)
        #expect(MachineImageOption.verified.reference == "ghcr.io/linuxcontainers/alpine:3.20")
        #expect(MachineImageOption.curated.map(\.reference).contains("ubuntu:24.04"))
    }

    @Test func resizeSettingsAndPreview() {
        let settings = MachineResize.settings(cpus: 8, memoryGB: 16)
        #expect(settings == ["cpus": "8", "memory": "16G"])
        #expect(MachineResize.previewCommand(name: "dev", settings: settings) == "container machine set -n dev cpus=8 memory=16G")
    }

    // MARK: CLI 1.5.0 golden flags
    //
    // Every flag a create/build sheet can emit must exist in the CLI's own `--help` (Fixtures/CLIHelpFixtures.swift).

    static func helpFlags(_ help: String) -> Set<String> {
        Set(help.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "[" || $0 == "]" || $0 == "(" || $0 == ")" })
            .map(String.init)
            .filter { $0.wholeMatch(of: /--?[a-zA-Z][a-zA-Z0-9-]*/) != nil })
    }

    static func flags(in arguments: [String]) -> [String] { arguments.filter { $0.hasPrefix("-") && $0.count > 1 } }

    @Test func machineCreateFlagsExistInHelp() {
        let help = Self.helpFlags(CLIHelpFixtures.machineCreate)
        #expect(help.contains("--home-mount") && !help.contains("--user"))
        var form = MachineForm(host: HostResources(cpus: 8, memoryBytes: 16 << 30))
        form.setDefault = true
        form.bootNow = false
        form.homeMount = .readOnly
        form.virtualization = true
        form.kernelPath = "/k/vmlinux"
        var spec = form.spec
        spec.platform = .amd64
        let used = Self.flags(in: spec.cliArguments)
        #expect(used.count == 9)
        for flag in used { #expect(help.contains(flag), "machine create has no \(flag)") }
    }

    @Test func clusterCreateFlagsExistInHelp() {
        let help = Self.helpFlags(CLIHelpFixtures.k8sCreate)
        var form = ClusterForm(host: HostResources(cpus: 8, memoryBytes: 16 << 30))
        form.nodeImage = "docker.io/kindest/node:v1.34.0"
        form.cniManifestPath = "/tmp/cni.yaml"
        form.removeOnStop = true
        let used = Self.flags(in: form.spec.cliArguments)
        #expect(Set(used) == ["--name", "-c", "-m", "--node-image", "--cni", "--rm"])
        for flag in used { #expect(help.contains(flag), "k8s create has no \(flag)") }
        #expect(!help.contains("--workers"))
    }

    @Test func buildFlagsExistInHelp() {
        let help = Self.helpFlags(CLIHelpFixtures.build)
        var spec = BuildSpec(contextDirectory: "/ctx", tag: "app:1")
        spec.dockerfile = "Dockerfile"
        spec.platforms = [.arm64, .amd64]
        spec.buildArgs = ["A=1"]
        spec.target = "runtime"
        spec.noCache = true
        spec.pull = true
        spec.labels = ["k=v"]
        spec.secrets = ["id=a,env=B"]
        spec.forwardSSH = true
        spec.cpus = 2
        spec.memory = MemorySize(bytes: 2 << 30)
        spec.output = "type=oci,dest=/tmp/x.tar"
        let used = Set(Self.flags(in: spec.resolvingPaths().cliArguments))
        #expect(used.count == 14)
        for flag in used { #expect(help.contains(flag), "build has no \(flag)") }
    }

    // MARK: Kubernetes

    @Test(arguments: [
        (4, 8, 2, 2),       // small Mac: minimums
        (12, 64, 3, 16),    // quarter
        (16, 128, 4, 32),
        (1, 1, 1, 1),       // minimums never exceed the host
    ])
    func clusterDefaultSizing(cpus: Int, ramGB: Int64, expectCPUs: Int, expectGB: Int) {
        let host = HostResources(cpus: cpus, memoryBytes: ramGB << 30)
        #expect(host.clusterDefaultCPUs == expectCPUs)
        #expect(host.clusterDefaultMemoryGB == expectGB)
        let form = ClusterForm(host: host)
        #expect(form.cpus == expectCPUs && form.memoryGB == expectGB)
    }

    @Test func clusterPreviewOmitsDefaultsAndWorkers() {
        var form = ClusterForm(host: HostResources(cpus: 12, memoryBytes: 64 << 30))
        form.name = "cd-ui-test"
        #expect(form.previewCommand() == "container k8s create --name cd-ui-test -c 3 -m 16G")
        #expect(form.spec.workers == nil)
        form.nodeImage = "docker.io/kindest/node:v1.34.0"
        form.cniManifestPath = "/tmp/cilium.yaml"
        form.removeOnStop = true
        #expect(form.previewCommand() ==
            "container k8s create --name cd-ui-test -c 3 -m 16G --node-image docker.io/kindest/node:v1.34.0 --cni /tmp/cilium.yaml --rm")
    }

    @Test func kubectlCommands() {
        #expect(KubectlCommands.context("k8s-dev") == "kubectl --context k8s-dev")
        #expect(KubectlCommands.quick("x").contains { $0.command == "kubectl --context x get nodes -o wide" })
    }

    // MARK: Registries

    @Test(arguments: ["docker.io", "ghcr.io", "localhost:5000", "registry.example.com/team", "Example.COM/"])
    func validRegistryServers(_ server: String) {
        #expect(RegistryServerRule.validate(server) == nil)
    }

    @Test(arguments: ["", "https://ghcr.io", "http://localhost:5000", "my registry", "-bad.com", "host:abc"])
    func invalidRegistryServers(_ server: String) {
        #expect(RegistryServerRule.validate(server) != nil)
    }

    @Test func registryPresets() {
        #expect(RegistryPreset.dockerHub.server == "docker.io")
        #expect(RegistryPreset.ghcr.server == "ghcr.io")
        #expect(RegistryPreset.custom.server == nil)
        #expect(RegistryPreset.dockerHub.hint.contains("access token"))
        #expect(RegistryPreset.ghcr.hint.contains("write:packages"))
        #expect(!RegistryPreset.dockerHub.allowsHTTP && !RegistryPreset.ghcr.allowsHTTP && RegistryPreset.custom.allowsHTTP)
        #expect(RegistryPreset.matching(server: "GHCR.io/") == .ghcr)
        #expect(RegistryPreset.matching(server: "quay.io") == .custom)
        #expect(RegistryServerRule.normalize(" Docker.IO/ ") == "docker.io")
    }

    /// Recorded from the real engine (CLI 1.5.0, 2026-10-19): the CLUSTER cell is blank.
    @Test func parsesRealK8sListWithBlankClusterColumn() {
        let text = """
        CLUSTER  NODE        ROLE                  STATE    CPUS  MEMORY    ADDR           PORTS
                 cd-ui-test  control-plane,worker  running  4     32768 MB  192.168.64.36
        """
        let clusters = CLIOutputParsing.clusters(text)
        #expect(clusters.map(\.name) == ["cd-ui-test"])
        let node = clusters.first?.nodes.first
        #expect(node?.role == "control-plane,worker")
        #expect(node?.state == .running)
        #expect(node?.cpus == 4)
        #expect(node?.memoryMB == 32768)
        #expect(node?.address == "192.168.64.36")
        #expect(clusters.first?.isRunning == true)
    }

    // MARK: Stores

    @MainActor @Test func machineCreateResizeAndInspect() async {
        let model = TestSupport.model()
        var form = MachineForm(host: HostResources(cpus: 8, memoryBytes: 16 << 30))
        form.name = "cd-ui-test"
        await model.machines.create(form.spec).wait()
        #expect(model.machines.items.contains { $0.name == "cd-ui-test" && $0.isRunning })
        #expect(await model.machines.configure("cd-ui-test", settings: MachineResize.settings(cpus: 3, memoryGB: 5)))
        #expect(model.machines.items.first { $0.name == "cd-ui-test" }?.cpus == 3)
        #expect(await model.machines.inspect("cd-ui-test")?.image?.reference == "ghcr.io/linuxcontainers/alpine:3.20")
        #expect(await model.machines.inspect("missing") == nil)
    }
}
