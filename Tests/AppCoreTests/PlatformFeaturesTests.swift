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
            "container machine create --name cd-ui-test --cpus 2 --memory 2g --home-mount rw --set-default ghcr.io/linuxcontainers/alpine:3.20")
        #expect(form.previewCommand() == CommandLine(executable: "container",
                                                     arguments: ["machine", "create"] + form.spec.cliArguments).display)
    }

    @Test func machineFormBootUserAndVirtualization() {
        var form = MachineForm(host: HostResources(cpus: 8, memoryBytes: 16 << 30))
        form.bootNow = false
        form.homeMount = .none
        form.uid = "1000"
        form.gid = "1000"
        #expect(form.spec.noBoot)
        #expect(form.spec.user == "1000:1000")
        form.username = "me"
        form.gid = ""
        #expect(form.spec.user == "me")
        form.virtualization = true
        #expect(form.kernelError != nil)
        #expect(!form.isValid)
        form.kernelPath = "/k/vmlinux"
        #expect(form.isValid)
        #expect(form.previewCommand().contains("--home-mount none --no-boot --virtualization --kernel /k/vmlinux --user me"))
    }

    @Test func machineFormRejectsBadUID() {
        var form = MachineForm(host: HostResources(cpus: 4, memoryBytes: 8 << 30))
        form.uid = "abc"
        #expect(form.userError != nil)
        #expect(!form.isValid)
    }

    @Test func curatedImagesAndBrokenAlpine() {
        #expect(MachineImageOption.curated.first?.support == .verified)
        #expect(MachineImageOption.curated.map(\.reference).contains("ubuntu:24.04"))
        #expect(MachineImageOption.knownBroken("alpine:latest"))
        #expect(MachineImageOption.knownBroken("docker.io/library/alpine:3.20"))
        #expect(!MachineImageOption.knownBroken("ghcr.io/linuxcontainers/alpine:3.20"))
    }

    @Test func resizeSettings() {
        #expect(MachineResize.settings(cpus: 8, memoryGB: 16) == ["cpus": "8", "memory": "16g"])
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
        #expect(form.previewCommand() == "container k8s create --name cd-ui-test -c 3 -m 16g")
        #expect(form.spec.workers == nil)
        form.nodeImage = "docker.io/kindest/node:v1.34.0"
        form.cniManifestPath = "/tmp/cilium.yaml"
        form.removeOnStop = true
        #expect(form.previewCommand() ==
            "container k8s create --name cd-ui-test -c 3 -m 16g --node-image docker.io/kindest/node:v1.34.0 --cni /tmp/cilium.yaml --rm")
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
