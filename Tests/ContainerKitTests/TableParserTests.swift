import ContainerKitMock
import Foundation
import Testing

@testable import ContainerKit

@Suite("TableParser and CLI output parsing")
struct TableParserTests {
    @Test func k8sListFixtureHasThreeBlankClusterRows() {
        let table = TableParser.parse(Fixtures.text("k8s-list.txt"))
        #expect(table.headers == ["CLUSTER", "NODE", "ROLE", "STATE", "CPUS", "MEMORY", "ADDR", "PORTS"])
        #expect(table.rows.count == 3)
        let clusters = CLIOutputParsing.clusters(Fixtures.text("k8s-list.txt"))
        #expect(clusters.map(\.name) == ["k8s-dev", "staging", "cd-ui-test"])
        #expect(clusters.map(\.nodes.count) == [1, 1, 1])
        #expect(clusters[1].nodes[0].state == .stopped)
        #expect(clusters[1].nodes[0].address == nil)
        #expect(clusters[2].nodes[0].memoryMB == 32768)
        #expect(clusters[0].isRunning && !clusters[1].isRunning)
    }

    @Test func emptyK8sList() {
        #expect(CLIOutputParsing.clusters("CLUSTER  NODE  ROLE  STATE  CPUS  MEMORY  ADDR  PORTS\n").isEmpty)
    }

    /// Two lone control-plane rows with blank CLUSTER must not merge; a blank worker row joins the cluster above it.
    @Test func k8sListBlankClusterControlPlanesStartNewClusters() {
        let text = """
            CLUSTER  NODE         ROLE           STATE    CPUS  MEMORY   ADDR           PORTS
                     alpha        control-plane  running  2     4096 MB  192.168.64.10
                     alpha-w1     worker         running  2     2048 MB  192.168.64.11
                     beta         control-plane  stopped  2     4096 MB
            """
        let clusters = CLIOutputParsing.clusters(text)
        #expect(clusters.map(\.name) == ["alpha", "beta"])
        #expect(clusters[0].nodes.map(\.name) == ["alpha", "alpha-w1"])
        #expect(clusters[1].nodes.map(\.name) == ["beta"])
    }

    @Test func k8sListLeadingBlankWorkerBecomesItsOwnCluster() {
        let text = """
            CLUSTER  NODE   ROLE     STATE    CPUS  MEMORY   ADDR  PORTS
                     lone   worker   running  1     1024 MB
            """
        #expect(CLIOutputParsing.clusters(text).map(\.name) == ["lone"])
    }

    @Test func systemStatusFixtureKeepsSpacesAndEmptyCells() {
        let values = TableParser.keyValues(Fixtures.text("system-status.txt"))
        #expect(values["status"] == "running")
        #expect(values["host.os"] == "Version 26.6.2 (Build 25G83)")
        #expect(values["paths.appRoot"] == "/Users/ilessio/Library/Application Support/com.apple.container/")
        #expect(values["paths.logRoot"] == "")
        #expect(values["images.total"] == "13")
        #expect(values.count == 17)
    }

    @Test func systemVersionFixture() {
        let table = TableParser.parse(Fixtures.text("system-version.txt"))
        #expect(table.headers == ["COMPONENT", "VERSION", "BUILD", "COMMIT"])
        #expect(table.column("COMPONENT") == ["container", "container-apiserver"])
        #expect(table.records.allSatisfy { $0["VERSION"] == "1.5.0" && $0["BUILD"] == "release" })
        #expect(table.records[1]["COMMIT"] == "d265d669ecae041bf338cb3b39c4118316d138f0")
    }

    @Test func k8sListWithNodes() {
        let text = """
            CLUSTER   NODE                    ROLE           STATE    CPUS  MEMORY   ADDR             PORTS
            k8s-dev   k8s-dev-control-plane   control-plane  running  4     4096 MB  192.168.64.50    127.0.0.1:6443->6443/tcp
            k8s-dev   k8s-dev-worker          worker         stopped  2     2g
            other     other-control-plane     control-plane  running  2     2048     192.168.64.51    -
            """
        let clusters = CLIOutputParsing.clusters(text)
        #expect(clusters.map(\.name) == ["k8s-dev", "other"])
        let dev = clusters[0]
        #expect(dev.nodes.count == 2)
        #expect(dev.nodes[0].role == "control-plane")
        #expect(dev.nodes[0].state == .running)
        #expect(dev.nodes[0].cpus == 4)
        #expect(dev.nodes[0].memoryMB == 4096)
        #expect(dev.nodes[0].address == "192.168.64.50")
        #expect(dev.nodes[0].ports == "127.0.0.1:6443->6443/tcp")
        #expect(dev.nodes[1].state == .stopped)
        #expect(dev.nodes[1].memoryMB == 2048)
        #expect(dev.nodes[1].address == nil)
        #expect(clusters[1].nodes[0].ports == nil)
        #expect(clusters[1].nodes[0].memoryMB == 2048)
    }

    @Test func dnsTableAndJSON() {
        #expect(CLIOutputParsing.dnsDomains(Data("DOMAIN\n".utf8)).isEmpty)
        #expect(CLIOutputParsing.dnsDomains(Data("[]".utf8)).isEmpty)
        let table = "DOMAIN\ntest\nlocal.dev\n"
        #expect(CLIOutputParsing.dnsDomains(Data(table.utf8)).map(\.domain) == ["test", "local.dev"])
        let json = #"[{"domain":"test","localhost":"203.0.113.1"},"plain",{"name":"named"}]"#
        let parsed = CLIOutputParsing.dnsDomains(Data(json.utf8))
        #expect(
            parsed == [
                DNSDomain(domain: "test", localhostAddress: "203.0.113.1"), DNSDomain(domain: "plain"),
                DNSDomain(domain: "named"),
            ])
    }

    @Test func registryTableAndJSON() {
        #expect(CLIOutputParsing.registries(Data("HOSTNAME  USERNAME  MODIFIED  CREATED\n".utf8)).isEmpty)
        let table = """
            HOSTNAME             USERNAME   MODIFIED              CREATED
            docker.io            ilessio    2026-10-17 18:00:00   2026-10-01 09:00:00
            ghcr.io              robot      2026-10-17 18:00:00   2026-10-01 09:00:00
            """
        let rows = CLIOutputParsing.registries(Data(table.utf8))
        #expect(
            rows == [
                RegistryLogin(server: "docker.io", username: "ilessio"),
                RegistryLogin(server: "ghcr.io", username: "robot"),
            ])
        let json =
            #"[{"id":"docker.io","name":"docker.io","username":"ilessio","creationDate":"2026-10-01T09:00:00Z"},{"id":"ghcr.io","username":"robot"}]"#
        #expect(CLIOutputParsing.registries(Data(json.utf8)).map(\.server) == ["docker.io", "ghcr.io"])
        #expect(CLIOutputParsing.registries(Data(json.utf8)).map(\.username) == ["ilessio", "robot"])
    }

    @Test func misalignedRowFallsBackToSplitting() {
        let text = "NAME  VALUE\nlonger-than-header  x y\n"
        let table = TableParser.parse(text)
        #expect(table.rows == [["longer-than-header", "x y"]])
    }

    @Test func cliVersionBanner() {
        #expect(
            CLIOutputParsing.cliVersion("container CLI version 1.5.0 (build: release, commit: d265d66)\n") == "1.5.0")
        #expect(CLIOutputParsing.cliVersion("1.6.0-beta") == "1.6.0-beta")
    }
}
