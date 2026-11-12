import ContainerKit
import Foundation
import Testing

@testable import AppCore

/// The compose files of `Tests/ContainerKitTests/Resources/compose`, read straight from the source tree (they
/// are resources of the other test target; one copy only).
enum ComposeSamples {
    static let folder = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "ContainerKitTests/Resources/compose")

    static func text(_ name: String) throws -> String {
        try String(contentsOf: folder.appending(path: name), encoding: .utf8)
    }

    static func project(
        _ name: String, directory: String = "/proj", variables: [String: String] = [:]
    ) throws -> ComposeProject {
        ComposeProject(file: try ComposeParser.parse(text(name), variables: variables), directory: directory)
    }

    static func inline(_ yaml: String, directory: String = "/proj") throws -> ComposeProject {
        ComposeProject(file: try ComposeParser.parse(yaml), directory: directory)
    }

    /// Plans without touching the file system: every path "exists" unless listed in `missing`.
    static func plan(
        _ project: ComposeProject, options: ComposeOptions = ComposeOptions(),
        environment: ComposeEnvironment = ComposeEnvironment(), missing: Set<String> = []
    ) -> ComposePlan {
        ComposePlanner.plan(project, options: options, environment: environment, home: "/Users/me") {
            !missing.contains($0)
        }
    }
}

extension ComposePlan {
    func runSpec(_ name: String) -> RunSpec? {
        for step in steps {
            if case .runContainer(let spec) = step.action, spec.name == name { return spec }
        }
        return nil
    }
}

private let projectLabel = "io.aiflowlabs.containerdesktop.project"

@Suite("Compose planning")
struct ComposePlannerTests {
    @Test func webStackStepsInDependencyOrder() throws {
        let plan = ComposeSamples.plan(try ComposeSamples.project("web-stack.yaml"))
        #expect(plan.projectName == "shop")
        #expect(plan.problems.isEmpty)
        #expect(
            plan.steps.map(\.id) == [
                "volume:shop_pgdata", "volume:shop_redisdata",
                "pull:ghcr.io/example/shop-web:1.4", "pull:postgres:16-alpine", "pull:redis:7",
                "run:db", "run:cache", "run:web",
            ])
        #expect(plan.canRun)
        #expect(plan.containerNames == ["db", "cache", "web"])
    }

    @Test func webStackExactArguments() throws {
        let plan = ComposeSamples.plan(try ComposeSamples.project("web-stack.yaml"))
        let labels = { (service: String) in
            [
                "-l", "com.docker.compose.project=shop", "-l", "com.docker.compose.service=\(service)",
                "-l", "\(projectLabel)=shop",
            ]
        }
        #expect(
            plan.runSpec("db")?.cliArguments
                == [
                    "-d", "--name", "db", "-e", "POSTGRES_USER=shop", "-e", "POSTGRES_PASSWORD=secret",
                    "-e", "POSTGRES_DB=shop", "-v", "shop_pgdata:/var/lib/postgresql/data",
                    "-v", "/proj/initdb:/docker-entrypoint-initdb.d:ro", "-c", "2", "-m", "2G",
                ] + labels("db") + ["postgres:16-alpine"])
        #expect(
            plan.runSpec("cache")?.cliArguments
                == ["-d", "--name", "cache", "-v", "shop_redisdata:/data"] + labels("cache")
                + ["redis:7", "redis-server", "--appendonly", "yes"])
        #expect(
            plan.runSpec("web")?.cliArguments
                == [
                    "-d", "--name", "web", "-e", "DATABASE_URL=postgres://shop:secret@db:5432/shop",
                    "-e", "REDIS_URL=redis://cache:6379", "-e", "NODE_ENV=production", "-p", "8080:3000/tcp",
                    "-w", "/app", "-u", "1000:1000",
                    "-l", "com.docker.compose.project=shop", "-l", "com.docker.compose.service=web",
                    "-l", "com.example.tier=frontend", "-l", "\(projectLabel)=shop",
                    "ghcr.io/example/shop-web:1.4", "npm", "run", "start", "--", "--port", "3000",
                ])
        // The other step kinds, as shown in the preview.
        #expect(
            plan.steps[0].commandLine()
                == "container volume create --label com.docker.compose.project=shop "
                + "--label com.docker.compose.volume=pgdata --label \(projectLabel)=shop -- shop_pgdata")
        #expect(plan.steps[3].commandLine() == "container image pull -- postgres:16-alpine")
        // Secrets are masked in the preview and present in what runs.
        let db = try #require(plan.steps.first { $0.id == "run:db" })
        #expect(db.commandLine(maskSecrets: true).contains("POSTGRES_PASSWORD=…"))
        #expect(db.commandLine(maskSecrets: false).contains("POSTGRES_PASSWORD=secret"))
        #expect(plan.containsSecrets)
    }

    @Test func buildServicesExactArguments() throws {
        let plan = ComposeSamples.plan(try ComposeSamples.project("build.yaml", directory: "/work/My App"))
        #expect(plan.projectName == "myapp")  // folder name, made safe
        #expect(plan.steps.map(\.id) == ["build:api", "build:worker", "run:worker", "run:api"])
        guard case .buildImage(let api) = plan.steps[0].action, case .buildImage(let worker) = plan.steps[1].action
        else {
            Issue.record("expected two build steps")
            return
        }
        #expect(
            api.cliArguments == [
                "-t", "example/api:dev", "--progress", "plain", "-f", "/work/My App/api/Dockerfile.dev",
                "--build-arg", "NODE_VERSION=22", "--build-arg", "GIT_SHA=abc123", "--target", "dev",
                "/work/My App/api",
            ])
        #expect(worker.cliArguments == ["-t", "myapp-worker:latest", "--progress", "plain", "/work/My App/worker"])
        #expect(
            plan.steps[1].commandLine()
                == "container build -t myapp-worker:latest --progress plain '/work/My App/worker'")
        let labels = { (service: String) in
            [
                "-l", "com.docker.compose.project=myapp", "-l", "com.docker.compose.service=\(service)",
                "-l", "\(projectLabel)=myapp",
            ]
        }
        // Multi-word entrypoint: the first word is `--entrypoint`, the rest leads the arguments.
        #expect(
            plan.runSpec("worker")?.cliArguments
                == ["-d", "-i", "-t", "--name", "worker", "--entrypoint", "python", "--tmpfs", "/tmp"]
                + ["--platform", "linux/amd64"] + labels("worker")
                + ["--init", "--read-only", "--dns", "1.1.1.1", "myapp-worker:latest", "-m", "worker"]
                + ["--queues", "default"])
        #expect(
            plan.runSpec("api")?.cliArguments
                == ["-d", "--name", "api", "--env-file", "/work/My App/.env.api", "-p", "3000:3000/tcp"]
                + labels("api") + ["example/api:dev"])
    }

    @Test func longSyntaxWithNetworksFromTheFile() throws {
        var options = ComposeOptions()
        options.networking = .asDeclared
        options.enabledProfiles = ["full"]
        var environment = ComposeEnvironment()
        environment.isLoaded = true
        environment.dnsDomain = "test"
        let plan = ComposeSamples.plan(
            try ComposeSamples.project("long-syntax.yaml", directory: "/p"), options: options,
            environment: environment, missing: ["/p/local.env"])
        #expect(plan.problems.isEmpty)
        #expect(
            plan.steps.map(\.id) == [
                "network:longform_frontend", "network:longform_backend", "volume:tls-certs",
                "pull:nginx:1.27", "pull:example/app", "run:app", "run:edge-proxy",
            ])
        #expect(
            plan.steps[1].commandLine()
                == "container network create --subnet 192.168.90.0/24 --label com.docker.compose.network=backend "
                + "--label com.docker.compose.project=longform --label \(projectLabel)=longform -- longform_backend")
        #expect(
            plan.runSpec("edge-proxy")?.cliArguments
                == [
                    "-d", "--name", "edge-proxy", "--env-file", "/p/common.env",
                    "-p", "127.0.0.1:8080:80/tcp", "-p", "5353:53/udp", "-p", "9000:9000/tcp", "-p", "9001:9001/tcp",
                    "-p", "9002:9002/tcp", "-p", "[::1]:8443:443/tcp",
                    "-v", "/p/nginx.conf:/etc/nginx/nginx.conf:ro", "-v", "tls-certs:/etc/ssl/private",
                    "-v", "/var/log/nginx", "--tmpfs", "/var/cache/nginx:size=64M", "-c", "2", "-m", "512M",
                    "--network", "longform_frontend",
                    "-l", "com.docker.compose.project=longform", "-l", "com.docker.compose.service=proxy",
                    "-l", "\(projectLabel)=longform",
                    "--cap-add", "NET_BIND_SERVICE", "--cap-drop", "ALL", "--shm-size", "128M",
                    "--ulimit", "nofile=1024:2048", "--ulimit", "nproc=512",
                    "--network", "longform_backend", "nginx:1.27",
                ])
        #expect(plan.runSpec("app")?.network == "longform_backend")
        // 1.5 CPUs cannot be expressed; the plan says so.
        #expect(plan.warnings.contains { $0.scope == .service("proxy") && $0.key == "cpus" })
        // Custom networks: no promise of name resolution, even with a DNS domain.
        #expect(plan.services.allSatisfy { $0.hostnames.isEmpty })
        #expect(plan.namingSummary.contains("IP address only"))
    }

    @Test func sharedDefaultNetworkIsTheDefaultAndSaysSo() throws {
        var environment = ComposeEnvironment()
        environment.isLoaded = true
        environment.dnsDomain = "test"
        var options = ComposeOptions()
        options.enabledProfiles = ["full"]
        let plan = ComposeSamples.plan(
            try ComposeSamples.project("long-syntax.yaml"), options: options, environment: environment)
        #expect(!plan.steps.contains { $0.id.hasPrefix("network:") })
        #expect(plan.runSpec("edge-proxy")?.network == nil)
        #expect(plan.runSpec("edge-proxy")?.cliArguments.contains("--network") == false)
        #expect(plan.warnings.contains { $0.scope == .file && $0.key == "networks" })
        let proxy = try #require(plan.services.first { $0.name == "proxy" })
        #expect(proxy.containerName == "edge-proxy")
        #expect(proxy.hostnames == ["edge-proxy", "edge-proxy.test"])
        #expect(plan.namingSummary.contains("“test”"))
    }

    @Test func noDNSDomainMeansNoHostnames() throws {
        var environment = ComposeEnvironment()
        environment.isLoaded = true
        let plan = ComposeSamples.plan(try ComposeSamples.project("web-stack.yaml"), environment: environment)
        #expect(plan.services.allSatisfy { $0.hostnames.isEmpty })
        #expect(plan.namingSummary.contains("No DNS domain"))
        #expect(plan.warnings.contains { $0.key == "names" })
        // Unknown (engine stopped) is worded differently from "none".
        let unknown = ComposeSamples.plan(try ComposeSamples.project("web-stack.yaml"))
        #expect(unknown.namingSummary.contains("could not be checked"))
    }

    @Test func projectPrefixedNamingAndProjectNameOverride() throws {
        var options = ComposeOptions()
        options.naming = .projectPrefixed
        options.projectName = "staging"
        let plan = ComposeSamples.plan(try ComposeSamples.project("web-stack.yaml"), options: options)
        #expect(plan.containerNames == ["staging-db", "staging-cache", "staging-web"])
        #expect(plan.steps.first?.id == "volume:staging_pgdata")
        #expect(plan.runSpec("staging-db")?.labels[projectLabel] == "staging")
        #expect(plan.warnings.contains { $0.key == "names" && $0.message.contains("staging-") })
        options.projectName = "Not Valid!"
        #expect(!ComposeSamples.plan(try ComposeSamples.project("web-stack.yaml"), options: options).canRun)
    }

    @Test func profilesAreOffByDefault() throws {
        let project = try ComposeSamples.project("long-syntax.yaml")
        let plan = ComposeSamples.plan(project)
        // proxy depends on app, whose profile is off: blocked with a clear reason.
        #expect(plan.services.first { $0.name == "app" }?.isEnabled == false)
        #expect(plan.problems.contains { $0.message.contains("switched off") && $0.service == "proxy" })
        #expect(!plan.canRun)
    }

    @Test func dependencyCycleIsAnError() throws {
        let project = try ComposeSamples.inline(
            """
            services:
              a: {image: x, depends_on: [b]}
              b: {image: x, depends_on: [c]}
              c: {image: x, depends_on: [a]}
              d: {image: x}
            """)
        let (order, cycle) = ComposePlanner.startOrder(project.file.services)
        #expect(order.isEmpty)
        #expect(cycle == ["a", "b", "c", "a"])
        let plan = ComposeSamples.plan(project)
        #expect(plan.problems.contains { $0.message.contains("a → b → c → a") })
        #expect(!plan.canRun)
    }

    @Test func startOrderKeepsFileOrderAmongEquals() throws {
        let project = try ComposeSamples.inline(
            """
            services:
              web: {image: x, depends_on: [api]}
              api: {image: x, depends_on: {db: {condition: service_healthy}, cache: {}}}
              extra: {image: x}
              db: {image: x}
              cache: {image: x}
            """)
        let (order, cycle) = ComposePlanner.startOrder(project.file.services)
        #expect(cycle == nil)
        #expect(order.map(\.name) == ["db", "cache", "api", "web", "extra"])
        let selfCycle = try ComposeSamples.inline("services:\n  a: {image: x, depends_on: [a]}\n")
        #expect(ComposePlanner.startOrder(selfCycle.file.services).cycle == ["a", "a"])
    }

    @Test func unknownDependencyMissingImageAndDuplicateNames() throws {
        let project = try ComposeSamples.inline(
            """
            services:
              a: {image: x, depends_on: [ghost], container_name: same, ports: ["80:80"]}
              b: {container_name: same}
              c: {image: y, ports: ["80:8080"]}
            """)
        let messages = ComposeSamples.plan(project).problems.map(\.message)
        #expect(messages.contains { $0.contains("“ghost”, which is not a service") })
        #expect(messages.contains { $0.contains("“b” has neither `image:` nor `build:`") })
        #expect(messages.contains { $0.contains("would both be named “same”") })
        #expect(messages.contains { $0.contains("Host port 80 is published by both") })
    }

    @Test func existingResourcesAreReusedBlockedOrReplaced() throws {
        var environment = ComposeEnvironment()
        environment.isLoaded = true
        environment.volumes = ["shop_pgdata"]
        environment.images = ["docker.io/library/redis:7", "docker.io/library/postgres:16-alpine"]
        environment.containers = [
            "db": .init(isRunning: true), "other": .init(isRunning: true, hostPorts: ["8080/tcp"]),
        ]
        let project = try ComposeSamples.project("web-stack.yaml")
        var plan = ComposeSamples.plan(project, environment: environment)
        // Existing volume: reused, not recreated. Local images: not pulled.
        #expect(plan.reused == ["volume shop_pgdata"])
        #expect(plan.steps.map(\.id).prefix(2) == ["volume:shop_redisdata", "pull:ghcr.io/example/shop-web:1.4"])
        // Existing container: blocks until the user opts into replacing it.
        #expect(plan.problems.map(\.kind) == [.containerExists(name: "db")])
        #expect(plan.problems[0].message.contains("is running"))
        #expect(!plan.canRun)
        #expect(plan.warnings.contains { $0.scope == .service("web") && $0.message.contains("“other”") })

        var options = ComposeOptions()
        options.replaceExisting = ["db"]
        plan = ComposeSamples.plan(project, options: options, environment: environment)
        #expect(plan.canRun)
        #expect(plan.containersToReplace == ["db"])
        let ids = plan.steps.map(\.id)
        #expect(ids.firstIndex(of: "remove:db")! + 1 == ids.firstIndex(of: "run:db")!)
        #expect(plan.steps.first { $0.id == "remove:db" }?.commandLine() == "container delete -f -- db")
    }

    @Test func externalResourcesMustExist() throws {
        let project = try ComposeSamples.inline(
            """
            services:
              a:
                image: x
                networks: [shared]
                volumes: ["legacy:/data", "undeclared:/other"]
            networks:
              shared: {external: true}
            volumes:
              legacy: {external: true}
            """)
        var options = ComposeOptions()
        options.networking = .asDeclared
        var plan = ComposeSamples.plan(project, options: options)
        #expect(plan.problems.count == 2)
        #expect(plan.problems.allSatisfy { $0.message.contains("must already exist") })
        // An undeclared volume is created anyway, with a note.
        #expect(plan.steps.contains { $0.id == "volume:proj_undeclared" })
        #expect(plan.warnings.contains { $0.scope == .volume("undeclared") })

        var environment = ComposeEnvironment()
        environment.networks = ["shared"]
        environment.volumes = ["legacy"]
        plan = ComposeSamples.plan(project, options: options, environment: environment)
        #expect(plan.problems.isEmpty)
        #expect(plan.reused == ["network shared", "volume legacy"])
        #expect(plan.runSpec("a")?.network == "shared")
        #expect(plan.runSpec("a")?.mounts.first?.cliArgument == "legacy:/data")
    }

    @Test func pathsEnvFilesAndPortNotes() throws {
        let project = try ComposeSamples.inline(
            """
            services:
              a:
                image: x
                ports: ["80"]
                env_file: [missing.env]
                volumes: ["~/data:/data", "./gone:/gone", "pg:/var/lib/postgresql/data"]
                mem_limit: 16m
            volumes: {pg: {}}
            """, directory: "/proj")
        let plan = ComposeSamples.plan(project, missing: ["/proj/missing.env", "/proj/gone"])
        let spec = try #require(plan.runSpec("a"))
        #expect(spec.mounts.map(\.cliArgument).prefix(2) == ["/Users/me/data:/data", "/proj/gone:/gone"])
        #expect(spec.ports.map(\.cliArgument) == ["80:80/tcp"])
        #expect(spec.memory == MemorySize(bytes: 64 << 20))
        #expect(plan.problems.contains { $0.message.contains("/proj/missing.env") })
        let notes = plan.warnings.filter { $0.scope == .service("a") }.map(\.key)
        #expect(Set(notes) == ["ports", "volumes", "mem_limit"])
        #expect(plan.warnings.contains { $0.message.contains("/proj/gone does not exist") })
        #expect(plan.warnings.contains { $0.message.contains("PGDATA") })
    }

    @Test func parserWarningsAndUnsetVariablesReachThePlan() throws {
        let plan = ComposeSamples.plan(try ComposeSamples.project("unsupported.yaml"))
        #expect(plan.warnings.contains { $0.scope == .service("app") && $0.key == "restart" })
        #expect(plan.warnings.contains { $0.scope == .file && $0.key == "include" })
        let interpolated = ComposeSamples.plan(
            try ComposeSamples.project("interpolation/compose.yaml", variables: ["TAG": "2.1"]))
        #expect(interpolated.projectName == "demo")
        #expect(interpolated.warnings.contains { $0.key == "variables" && $0.message.contains("NOT_SET_ANYWHERE") })
    }
}
