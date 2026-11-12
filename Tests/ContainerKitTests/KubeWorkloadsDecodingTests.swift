import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

/// The workloads decoders against what `kubectl` v1.35.5 really printed inside the control-plane node of a
/// container 1.7.1 cluster (`Resources/cli-1.7.1/kubectl-*.json`, recorded by
/// `scripts/record-kubectl-fixtures.sh` on 2026-11-12): a `shop` namespace with a two-pod `web` deployment
/// and its NodePort service, a crash-looping `worker` pod and a `reports` pod whose image cannot be pulled.
@Suite("Recorded kubectl workloads")
struct KubeWorkloadsDecodingTests {
    let cli = FixtureSet.cli171

    @Test func oneListIsSortedIntoItsKinds() throws {
        let workloads = try cli.clusterWorkloads()
        #expect(workloads.droppedCount == 0)
        #expect(workloads.pods.count == 14)
        #expect(workloads.deployments.map(\.id).sorted() == ["kube-system/coredns", "shop/web"])
        #expect(workloads.services.map(\.id).sorted() == ["default/kubernetes", "kube-system/kube-dns", "shop/web"])
        #expect(workloads.nodes.map(\.name).sorted() == ["cd-it-wl-dev", "cd-it-wl-dev-worker-1"])
        #expect(
            workloads.namespaces.map(\.name).sorted()
                == ["default", "kube-node-lease", "kube-public", "kube-system", "shop"])
        #expect(workloads.namespaces.filter { !$0.isSystem }.map(\.name).sorted() == ["default", "shop"])
    }

    @Test func podColumnsMatchWhatKubectlPrinted() throws {
        let pods = try cli.clusterWorkloads().pods
        let shop = Dictionary(uniqueKeysWithValues: pods.filter { $0.namespace == "shop" }.map { ($0.name, $0) })
        #expect(shop.count == 4)

        // `worker  0/1  CrashLoopBackOff  6 (…)`: waiting, with the previous instance's exit recorded.
        let worker = try #require(shop["worker"])
        #expect(worker.statusText == "CrashLoopBackOff")
        #expect(worker.readyText == "0/1")
        #expect(worker.restartCount >= 5)
        #expect(worker.health == .failing)
        #expect(worker.lastRestart != nil)
        #expect(worker.ownerName == nil)
        #expect(worker.statusMessage?.contains("back-off") == true)
        let container = try #require(worker.containerStatuses.first)
        #expect(container.stateText == "Waiting: CrashLoopBackOff")
        #expect(container.lastStateText == "Error (exit 1)")
        #expect(container.hasPreviousInstance)
        #expect(container.image == "docker.io/library/alpine:3.22")

        // `reports  0/1  ImagePullBackOff  0`: still Pending, never started.
        let reports = try #require(shop["reports"])
        #expect(reports.status?.phase == .pending)
        #expect(["ImagePullBackOff", "ErrImagePull"].contains(reports.statusText))
        #expect(reports.health == .failing)
        #expect(reports.restartCount == 0 && reports.lastRestart == nil)
        #expect(reports.statusMessage?.contains("registry.invalid/shop/reports:1.0") == true)
        #expect(reports.containerStatuses.first?.hasPreviousInstance == false)

        // The deployment's two pods: `1/1 Running 0`, owned by a ReplicaSet, on the worker node.
        let web = pods.filter { $0.name.hasPrefix("web-") }
        #expect(web.count == 2)
        for pod in web {
            #expect(pod.statusText == "Running" && pod.readyText == "1/1" && pod.health == .healthy)
            #expect(pod.restartCount == 0)
            #expect(pod.nodeName == "cd-it-wl-dev-worker-1")
            #expect(pod.ownerName?.hasPrefix("web-") == true)
            #expect(pod.metadata.creationTimestamp != nil && pod.status?.podIP != nil)
            #expect(pod.spec?.containers?.map(\.name) == ["web"])
        }

        // Every system pod was up.
        for pod in pods where pod.namespace == "kube-system" {
            #expect(pod.statusText == "Running" && pod.health == .healthy, "\(pod.name)")
        }
    }

    @Test func deploymentsServicesAndNodes() throws {
        let workloads = try cli.clusterWorkloads()
        let web = try #require(workloads.deployments.first { $0.id == "shop/web" })
        #expect(web.readyText == "2/2" && web.updatedReplicas == 2 && web.availableReplicas == 2)
        #expect(web.isSettled)
        #expect(web.spec?.selector?.matchLabels == ["app": "web"])
        #expect(workloads.pods(of: web).map(\.name).allSatisfy { $0.hasPrefix("web-") })
        #expect(workloads.pods(of: web).count == 2)

        let services = Dictionary(uniqueKeysWithValues: workloads.services.map { ($0.id, $0) })
        let service = try #require(services["shop/web"])
        #expect(service.type == "NodePort" && service.portsText == "80:30080/TCP")
        #expect(service.spec?.clusterIP?.hasPrefix("10.") == true)
        #expect(service.externalText == nil)
        #expect(services["kube-system/kube-dns"]?.portsText == "53/UDP,53/TCP,9153/TCP")
        #expect(services["default/kubernetes"]?.type == "ClusterIP")
        #expect(services["default/kubernetes"]?.portsText == "443/TCP")

        let nodes = Dictionary(uniqueKeysWithValues: workloads.nodes.map { ($0.name, $0) })
        let controlPlane = try #require(nodes["cd-it-wl-dev"])
        #expect(controlPlane.isReady && controlPlane.statusText == "Ready")
        #expect(controlPlane.roles == ["control-plane"])
        #expect(controlPlane.status?.nodeInfo?.kubeletVersion == "v1.35.5")
        #expect(controlPlane.internalIP?.hasPrefix("192.168.") == true)
        #expect(nodes["cd-it-wl-dev-worker-1"]?.roles == [])
    }

    @Test func eventsOfTheCrashLoopingPod() throws {
        let events = try cli.podEvents()
        #expect(!events.isEmpty)
        #expect(events.contains { $0.reason == "Scheduled" && !$0.isWarning })
        let backOff = try #require(events.first { $0.reason == "BackOff" })
        #expect(backOff.isWarning && (backOff.count ?? 0) > 1)
        #expect(backOff.message?.contains("restarting failed container") == true)
        #expect(events.allSatisfy { $0.lastSeen != nil && $0.source?.component != nil })
        #expect(Set(events.map(\.id)).count == events.count)
    }

    /// The recording must stay free of credentials: only resource descriptions, never kubeconfig or token data.
    @Test func recordingHoldsNoCredentials() {
        for name in ["kubectl-workloads.json", "kubectl-pod-events.json"] {
            let text = cli.text(name)
            for marker in [
                "BEGIN CERTIFICATE", "PRIVATE KEY", "certificate-authority-data", "client-key-data", "eyJhbGci",
            ] {
                #expect(!text.contains(marker), "\(name) contains \(marker)")
            }
            #expect(!text.contains("\"kind\": \"Secret\""))
        }
        #expect(cli.text("kubectl-not-found.txt").contains("(NotFound)"))
    }

    // MARK: Leniency (hand-written JSON)

    @Test func unknownValuesAndKindsNeverFailTheList() throws {
        let json = """
            {"kind": "List", "items": [
              {"kind": "Pod", "metadata": {"name": "odd", "namespace": "x"}, "status": {"phase": "Hibernating"}},
              {"kind": "Pod", "metadata": {"namespace": "no-name"}},
              {"kind": "CronJob", "metadata": {"name": "nightly"}},
              {"kind": "Service", "metadata": {"name": "bare"}},
              {"kind": "Deployment", "metadata": {"name": "empty", "namespace": "x"}},
              {"metadata": {"name": "kindless"}}
            ]}
            """
        let workloads = try CLIJSON.decode(ClusterWorkloads.self, from: Data(json.utf8))
        #expect(workloads.pods.map(\.name) == ["odd"])
        #expect(workloads.pods[0].status?.phase == .unknown)
        #expect(workloads.pods[0].statusText == "Unknown" && workloads.pods[0].readyText == "0/0")
        #expect(workloads.droppedCount == 1, "the pod without a name is skipped, not fatal")
        #expect(workloads.services.first?.namespace == "default" && workloads.services.first?.portsText == "")
        #expect(workloads.deployments.first?.readyText == "0/0")
        #expect(try CLIJSON.decode(ClusterWorkloads.self, from: Data("{}".utf8)) == ClusterWorkloads())
        #expect(try CLIJSON.decode(KubeList<KubeEvent>.self, from: Data(#"{"items": null}"#.utf8)).items.isEmpty)
    }

    @Test func statusFollowsKubectlsPrinter() {
        func pod(
            phase: KubePodPhase = .running, containers: [KubePod.ContainerStatus] = [],
            initContainers: [KubePod.ContainerStatus] = [], deleting: Bool = false, reason: String? = nil
        ) -> KubePod {
            KubePod(
                metadata: KubeMetadata(name: "p", namespace: "n", deletionTimestamp: deleting ? .now : nil),
                spec: .init(
                    containers: containers.map { .init(name: $0.name) },
                    initContainers: initContainers.map { .init(name: $0.name) }),
                status: .init(
                    phase: phase, reason: reason, conditions: [.init(type: "Ready", status: "True")],
                    containerStatuses: containers, initContainerStatuses: initContainers))
        }
        let running = KubePod.ContainerStatus(name: "a", ready: true, state: .init(running: .init()))
        let done = KubePod.ContainerStatus(
            name: "b", ready: false, state: .init(terminated: .init(reason: "Completed", exitCode: 0)))
        let killed = KubePod.ContainerStatus(name: "c", ready: false, state: .init(terminated: .init(signal: 9)))
        let oom = KubePod.ContainerStatus(
            name: "d", ready: false, restartCount: 2,
            state: .init(terminated: .init(reason: "OOMKilled", exitCode: 137)))
        let creating = KubePod.ContainerStatus(
            name: "e", ready: false, state: .init(waiting: .init(reason: "ContainerCreating")))

        #expect(pod(containers: [running]).statusText == "Running")
        #expect(pod(containers: [running]).health == .healthy)
        #expect(pod(phase: .succeeded, containers: [done]).statusText == "Completed")
        #expect(pod(phase: .succeeded, containers: [done]).health == .completed)
        #expect(
            pod(containers: [running, done]).statusText == "Running", "a finished sidecar does not hide a running pod")
        #expect(pod(containers: [killed]).statusText == "Signal:9")
        #expect(pod(containers: [oom]).statusText == "OOMKilled" && pod(containers: [oom]).health == .failing)
        #expect(oom.stateText == "Terminated: OOMKilled (exit 137)")
        #expect(pod(phase: .pending, containers: [creating]).statusText == "ContainerCreating")
        #expect(pod(phase: .pending, containers: [creating]).health == .progressing)
        #expect(pod(containers: [running], deleting: true).statusText == "Terminating")
        #expect(pod(phase: .failed, reason: "Evicted").statusText == "Evicted")
        #expect(pod(phase: .failed, reason: "Evicted").health == .failing)
        #expect(pod(phase: .pending).statusText == "Pending")

        let waitingInit = KubePod.ContainerStatus(name: "i", state: .init(waiting: .init(reason: "PodInitializing")))
        let failedInit = KubePod.ContainerStatus(
            name: "i", state: .init(terminated: .init(reason: "Error", exitCode: 1)))
        #expect(pod(phase: .pending, containers: [creating], initContainers: [waitingInit]).statusText == "Init:0/1")
        #expect(pod(phase: .pending, containers: [creating], initContainers: [failedInit]).statusText == "Init:Error")
    }
}
