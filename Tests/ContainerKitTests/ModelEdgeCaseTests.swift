import Foundation
import Testing

@testable import ContainerKit

@Suite("Model edge cases")
struct ModelEdgeCaseTests {
    static func image(_ reference: String) -> Image {
        Image(
            id: "abc",
            configuration: .init(
                name: reference, creationDate: .now,
                descriptor: Descriptor(digest: "sha256:abc", mediaType: "m", size: 1)),
            variants: [])
    }

    static let digest = "sha256:" + String(repeating: "a", count: 64)

    @Test(
        arguments: [
            ("docker.io/library/python:alpine", "python", "alpine"),
            ("docker.io/acme/app:1", "acme/app", "1"),
            ("localhost:5000/x:1", "localhost:5000/x", "1"),
            ("localhost:5000/x", "localhost:5000/x", nil),
            ("ghcr.io/o/r", "ghcr.io/o/r", nil),
            ("x@\(digest)", "x", nil),
            ("x:1@\(digest)", "x", "1"),
            ("localhost:5000/x@\(digest)", "localhost:5000/x", nil),
        ] as [(String, String, String?)])
    func imageRepositoryAndTag(reference: String, repository: String, tag: String?) {
        let image = Self.image(reference)
        #expect(image.repository == repository)
        #expect(image.tag == tag)
    }

    @Test func publishedPortURLsBracketIPv6() {
        typealias Port = Container.PublishedPort
        #expect(
            Port(hostAddress: "0.0.0.0", hostPort: 80, containerPort: 80).hostURL?.absoluteString
                == "http://127.0.0.1:80")
        #expect(
            Port(hostAddress: "::1", hostPort: 8080, containerPort: 80).hostURL?.absoluteString == "http://[::1]:8080")
        #expect(
            Port(hostAddress: "::", hostPort: 8080, containerPort: 80).hostURL?.absoluteString == "http://[::1]:8080")
        #expect(Port(hostAddress: "fd00::5", hostPort: 1, containerPort: 1).hostURL?.host == "fd00::5")
    }

    @Test func portMappingBracketsIPv6() {
        #expect(
            RunSpec.PortMapping(hostAddress: "::1", hostPort: 8080, containerPort: 80).cliArgument
                == "[::1]:8080:80/tcp")
        #expect(
            RunSpec.PortMapping(hostAddress: "[::1]", hostPort: 8080, containerPort: 80).cliArgument
                == "[::1]:8080:80/tcp")
        #expect(
            RunSpec.PortMapping(hostAddress: "127.0.0.1", hostPort: 8080, containerPort: 80).cliArgument
                == "127.0.0.1:8080:80/tcp")
    }

    @Test func machineSpecNeverPassesUser() {
        var spec = MachineSpec(image: "alpine:3.20", name: "dev")
        spec.cpus = 2
        spec.memory = MemorySize(parsing: "2g")
        #expect(spec.cliArguments == ["--name", "dev", "--cpus", "2", "--memory", "2G", "alpine:3.20"])
        #expect(!spec.cliArguments.contains("--user"))
    }
}
