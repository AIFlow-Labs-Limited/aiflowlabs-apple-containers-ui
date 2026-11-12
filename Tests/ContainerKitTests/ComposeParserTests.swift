import Foundation
import Testing

@testable import ContainerKit

/// Compose files under `Resources/compose`.
enum ComposeFixtures {
    static func text(_ name: String) throws -> String {
        let base = try #require(Bundle.module.url(forResource: "compose", withExtension: nil))
        return try String(contentsOf: base.appending(path: name), encoding: .utf8)
    }

    static func parse(_ name: String, variables: [String: String] = [:]) throws -> ComposeFile {
        try ComposeParser.parse(text(name), variables: variables)
    }
}

@Suite("Compose parsing")
struct ComposeParserTests {
    @Test func webStackShortSyntax() throws {
        let file = try ComposeFixtures.parse("web-stack.yaml")
        #expect(file.name == "shop")
        #expect(file.services.map(\.name) == ["web", "db", "cache"])
        #expect(file.volumes.map(\.key) == ["pgdata", "redisdata"])
        #expect(file.warnings.isEmpty)

        let web = try #require(file.service(named: "web"))
        #expect(web.image == "ghcr.io/example/shop-web:1.4")
        #expect(web.command == .shell("npm run start -- --port 3000"))
        #expect(web.ports == [ComposePort(published: 8080, target: 3000)])
        #expect(
            web.environment == [
                "DATABASE_URL=postgres://shop:secret@db:5432/shop", "REDIS_URL=redis://cache:6379",
                "NODE_ENV=production",
            ])
        #expect(web.dependsOn.map(\.service) == ["db", "cache"])
        #expect(web.workingDirectory == "/app")
        #expect(web.user == "1000:1000")
        #expect(web.labels == ["com.example.tier": "frontend"])

        let db = try #require(file.service(named: "db"))
        #expect(db.environment == ["POSTGRES_USER=shop", "POSTGRES_PASSWORD=secret", "POSTGRES_DB=shop"])
        #expect(
            db.mounts == [
                ComposeMount(source: .volume("pgdata"), target: "/var/lib/postgresql/data"),
                ComposeMount(source: .bind("./initdb"), target: "/docker-entrypoint-initdb.d", readOnly: true),
            ])
        #expect(db.memory == MemorySize(bytes: 2 << 30))
        #expect(db.cpus == 2)

        let cache = try #require(file.service(named: "cache"))
        #expect(cache.command == .exec(["redis-server", "--appendonly", "yes"]))
    }

    @Test func buildShortAndLongForms() throws {
        let file = try ComposeFixtures.parse("build.yaml")
        #expect(file.name == nil)
        let api = try #require(file.service(named: "api"))
        var expected = ComposeBuild(context: "./api")
        expected.dockerfile = "Dockerfile.dev"
        expected.target = "dev"
        expected.args = ["NODE_VERSION=22", "GIT_SHA=abc123"]
        #expect(api.build == expected)
        #expect(api.image == "example/api:dev")
        #expect(api.envFiles == [ComposeEnvFile(path: ".env.api")])
        #expect(api.dependsOn == [ComposeDependency(service: "worker")])

        let worker = try #require(file.service(named: "worker"))
        #expect(worker.build == ComposeBuild(context: "./worker"))
        #expect(worker.image == nil)
        #expect(worker.entrypoint == .exec(["python", "-m", "worker"]))
        #expect(worker.command == .shell("--queues default"))
        #expect(worker.useInit && worker.readOnly && worker.tty && worker.stdinOpen)
        #expect(worker.platform == "linux/amd64")
        #expect(worker.dns == ["1.1.1.1"])
        #expect(worker.mounts == [ComposeMount(source: .tmpfs(size: nil), target: "/tmp")])
        #expect(file.warnings.isEmpty)
    }

    @Test func longSyntaxPortsVolumesNetworks() throws {
        let file = try ComposeFixtures.parse("long-syntax.yaml")
        let proxy = try #require(file.service(named: "proxy"))
        #expect(proxy.containerName == "edge-proxy")
        #expect(
            proxy.ports == [
                ComposePort(hostAddress: "127.0.0.1", published: 8080, target: 80),
                ComposePort(published: 5353, target: 53, proto: "udp"),
                ComposePort(published: 9000, target: 9000), ComposePort(published: 9001, target: 9001),
                ComposePort(published: 9002, target: 9002),
                ComposePort(hostAddress: "::1", published: 8443, target: 443),
            ])
        #expect(
            proxy.mounts == [
                ComposeMount(source: .bind("./nginx.conf"), target: "/etc/nginx/nginx.conf", readOnly: true),
                ComposeMount(source: .volume("certs"), target: "/etc/ssl/private"),
                ComposeMount(source: .tmpfs(size: MemorySize(bytes: 64 << 20)), target: "/var/cache/nginx"),
                ComposeMount(source: .anonymous, target: "/var/log/nginx"),
            ])
        #expect(
            proxy.envFiles == [
                ComposeEnvFile(path: "common.env"), ComposeEnvFile(path: "local.env", isRequired: false),
            ])
        #expect(proxy.networks == ["frontend", "backend"])
        #expect(proxy.dependsOn == [ComposeDependency(service: "app", condition: "service_healthy")])
        #expect(proxy.cpus == 1.5)
        #expect(proxy.memory == MemorySize(bytes: 512 << 20))
        #expect(proxy.ulimits == ["nofile=1024:2048", "nproc=512"])
        #expect(proxy.capAdd == ["NET_BIND_SERVICE"])
        #expect(proxy.capDrop == ["ALL"])
        #expect(proxy.shmSize == MemorySize(bytes: 128 << 20))

        let app = try #require(file.service(named: "app"))
        #expect(app.profiles == ["full"])
        #expect(file.profiles == ["full"])

        #expect(file.networks.map(\.key) == ["frontend", "backend", "shared"])
        #expect(file.networks[1].subnet == "192.168.90.0/24")
        #expect(file.networks[2].isExternal)
        #expect(file.volumes[0].name == "tls-certs")
        #expect(file.volumes[1].isExternal)

        // Only the two things that cannot be honoured are reported.
        #expect(
            file.warnings.map(\.key).sorted() == ["depends_on.app.condition", "networks.backend.aliases"])
        #expect(file.warnings.first { $0.key == "depends_on.app.condition" }?.severity == .note)
    }

    @Test func unsupportedKeysBecomeWarningsNotErrors() throws {
        let file = try ComposeFixtures.parse("unsupported.yaml")
        #expect(file.services.map(\.name) == ["app", "db"])

        let appKeys = Set(file.warnings(for: .service("app")).map(\.key))
        #expect(
            appKeys == [
                "restart", "logging", "healthcheck", "deploy.replicas", "deploy.update_config",
                "deploy.resources.reservations", "secrets", "configs", "extends", "links", "network_mode",
                "privileged", "extra_hosts", "hostname", "ports", "some_future_key",
            ])
        // `restart: "no"` and `expose` are fine; the unsupported condition is a note.
        #expect(file.warnings(for: .service("db")).map(\.key) == ["depends_on.app.condition"])
        #expect(Set(file.warnings(for: .file).map(\.key)) == ["include", "secrets", "configs"])
        #expect(Set(file.warnings(for: .network("internal_net")).map(\.key)) == ["internal", "driver"])
        #expect(Set(file.warnings(for: .volume("nfs")).map(\.key)) == ["driver", "driver_opts"])

        // Both malformed port entries were dropped, each with its own message.
        let app = try #require(file.service(named: "app"))
        #expect(app.ports.isEmpty)
        #expect(file.warnings(for: .service("app")).filter { $0.key == "ports" }.count == 2)
        // The merge key (`<<: *defaults`) was applied: that is where `restart` came from.
        let restart = try #require(file.warnings.first { $0.key == "restart" })
        #expect(restart.message.contains("unless-stopped"))
        // Extension fields (`x-defaults`) and the obsolete `version` are silent.
        #expect(!file.warnings.contains { $0.key.hasPrefix("x-") || $0.key == "version" })
    }

    @Test func structuralProblemsThrow() {
        #expect(throws: ComposeError.self) { try ComposeParser.parse("services: [") }
        #expect(throws: ComposeError.self) { try ComposeParser.parse("just a string") }
        #expect(throws: ComposeError.self) { try ComposeParser.parse("volumes:\n  data:\n") }
        #expect(throws: ComposeError.self) { try ComposeParser.parse("services:\n  web:\n") }
        #expect(throws: ComposeError.self) { try ComposeParser.parse("") }
    }

    @Test func yamlErrorNamesTheLine() {
        do {
            _ = try ComposeParser.parse("services:\n  web:\n    image: nginx\n   bad: indent\n")
            Issue.record("expected a YAML error")
        } catch let ComposeError.invalidYAML(message) {
            #expect(message.contains("line 4"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test(arguments: [
        ("80", [ComposePort(published: nil, target: 80)]),
        ("8080:80", [ComposePort(published: 8080, target: 80)]),
        ("8080:80/udp", [ComposePort(published: 8080, target: 80, proto: "udp")]),
        ("127.0.0.1:8080:80", [ComposePort(hostAddress: "127.0.0.1", published: 8080, target: 80)]),
        ("127.0.0.1::80", [ComposePort(hostAddress: "127.0.0.1", published: nil, target: 80)]),
        ("[::1]:8080:80/TCP", [ComposePort(hostAddress: "::1", published: 8080, target: 80)]),
        (
            "3000-3001:4000-4001",
            [ComposePort(published: 3000, target: 4000), ComposePort(published: 3001, target: 4001)]
        ),
    ])
    func shortPorts(text: String, expected: [ComposePort]) {
        #expect(ComposeDecoder.shortPort(text) == expected)
    }

    @Test(arguments: ["", "abc", "80:", "0:80", "70000:80", "8080:80/sctp", "1-3:1-2", "a:b:c:d", "[::1]8080:80"])
    func malformedShortPorts(text: String) {
        #expect(ComposeDecoder.shortPort(text) == nil)
    }

    @Test func environmentListMapAndNullValues() throws {
        let yaml = """
            services:
              a:
                image: x
                environment:
                  FROM_HOST:
                  EMPTY: ""
                  NUMBER: 5432
                  FLAG: true
              b:
                image: x
                environment: [FROM_HOST, "KEY=a=b"]
            """
        let file = try ComposeParser.parse(yaml)
        #expect(file.services[0].environment == ["FROM_HOST", "EMPTY=", "NUMBER=5432", "FLAG=true"])
        #expect(file.services[1].environment == ["FROM_HOST", "KEY=a=b"])
    }

    @Test func volumeShortSyntaxVariants() throws {
        let yaml = """
            services:
              a:
                image: x
                volumes:
                  - /abs:/in/abs
                  - ~/home:/in/home:rw
                  - ../up:/in/up:ro,z
                  - named:/in/named:cached
                  - /anonymous
                  - a:b:c:d
                  - data:/x:nocopy
            """
        let file = try ComposeParser.parse(yaml)
        #expect(
            file.services[0].mounts == [
                ComposeMount(source: .bind("/abs"), target: "/in/abs"),
                ComposeMount(source: .bind("~/home"), target: "/in/home"),
                ComposeMount(source: .bind("../up"), target: "/in/up", readOnly: true),
                ComposeMount(source: .volume("named"), target: "/in/named"),
                ComposeMount(source: .anonymous, target: "/anonymous"),
                ComposeMount(source: .volume("data"), target: "/x"),
            ])
        #expect(file.warnings.count == 2)  // the 4-part entry and the unknown `nocopy` mode
    }
}
