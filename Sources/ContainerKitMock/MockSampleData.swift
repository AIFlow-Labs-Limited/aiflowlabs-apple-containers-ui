import ContainerKit
import Foundation

// Sample data for `MockBackend` beyond the recorded CLI fixtures: a realistic `acdemo` stack, common images,
// per-container logs and scrubbed fixture paths. Kept apart so `MockBackend.swift` stays about behaviour.
extension MockBackend {
    /// Decodes a fixture with the recording machine's home folder (`/Users/<name>/`) replaced by `/Users/you/`, so
    /// previews, screenshots and demos never show a real user name. The fixture files themselves stay verbatim.
    static func scrubbed<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let text = Fixtures.text(name).replacingOccurrences(
            of: #"/Users/[^/"]+/"#, with: "/Users/you/", options: .regularExpression)
        return try CLIJSON.decode(type, from: Data(text.utf8))
    }

    /// Common images next to the recorded ones, so the Images table looks like a working developer's.
    static func extraImages() -> [Image] {
        let samples: [(String, [Platform], Int64, Double)] = [
            ("docker.io/library/nginx:1.27-alpine", [.arm64, .amd64], 21_300_000, -86_400 * 12),
            ("docker.io/library/node:22-alpine", [.arm64, .amd64], 57_900_000, -86_400 * 6),
            ("docker.io/library/golang:1.23-alpine", [.arm64], 88_400_000, -86_400 * 20),
            ("docker.io/library/ubuntu:24.04", [.arm64, .amd64], 29_700_000, -86_400 * 30),
            ("ghcr.io/acme/edge-agent:0.4.2", [.arm64, .amd64], 64_100_000, -86_400 * 2),
        ]
        return samples.map { name, platforms, size, age in
            let digest = "sha256:" + fakeDigest(name)
            return Image(
                id: fakeDigest(name),
                configuration: .init(
                    name: name, creationDate: Date(timeIntervalSinceNow: age),
                    descriptor: Descriptor(
                        digest: digest, mediaType: "application/vnd.oci.image.index.v1+json", size: 1_600)),
                variants: platforms.map {
                    .init(platform: $0, digest: "sha256:" + fakeDigest(name + $0.architecture), size: size)
                })
        }
    }

    /// Volumes backing the `acdemo` stack (the fixture only has one probe volume).
    static func extraVolumes() -> [Volume] {
        [
            ("pgdata", 64 << 30, -86_400 * 3.0), ("cache-data", 8 << 30, -86_400 * 3.0),
            ("models", 256 << 30, -86_400 * 9.0),
        ]
        .map { name, size, age in
            Volume(
                id: name,
                configuration: .init(
                    name: name, creationDate: Date(timeIntervalSinceNow: age),
                    labels: name == "models" ? [:] : [AppLabel.project: "acdemo"], sizeInBytes: Int64(size),
                    source: "/Users/you/Library/Application Support/com.apple.container/volumes/\(name)/volume.img"))
        }
    }

    /// An isolated network for the `acdemo` stack next to the builtin `default`.
    static func extraNetworks() -> [Network] {
        [
            Network(
                id: "acdemo",
                configuration: .init(
                    name: "acdemo", creationDate: Date(timeIntervalSinceNow: -86_400 * 3),
                    labels: [AppLabel.project: "acdemo"]),
                status: .init(ipv4Gateway: "192.168.65.1", ipv4Subnet: "192.168.65.0/24", ipv6Subnet: nil))
        ]
    }

    /// Richer sample data than the single recorded container: a stopped one, a DB, a web app with ports.
    static func extraContainers() -> [Container] {
        func make(
            _ id: String, image: String, state: ContainerState, ip: String, ports: [Container.PublishedPort] = [],
            cmd: [String], labels: [String: String] = [:], memory: Int64 = 1 << 30,
            mounts: [Container.Mount] = [], env: [String] = []
        ) -> Container {
            let desc = Descriptor(
                digest: "sha256:" + fakeDigest(image),
                mediaType: "application/vnd.oci.image.index.v1+json", size: 1000)
            let config = Container.Configuration(
                id: id, image: ImageReference(reference: image, descriptor: desc),
                creationDate: Date(timeIntervalSinceNow: -3600 * Double(id.count)),
                resources: .init(cpus: 4, memoryInBytes: memory),
                initProcess: .init(
                    executable: cmd[0], arguments: Array(cmd.dropFirst()), environment: ["PATH=/usr/bin"] + env),
                labels: labels, mounts: mounts,
                networks: [.init(network: "default", options: .init(hostname: "\(id).test.", mtu: 1280))],
                publishedPorts: ports)
            let st =
                state == .running
                ? Container.Status(
                    state: .running, startedDate: Date(timeIntervalSinceNow: -1800),
                    networks: [.init(hostname: "\(id).test.", ipv4Address: "\(ip)/24")])
                : Container.Status(state: .stopped)
            return Container(id: id, configuration: config, status: st)
        }
        return [
            make(
                "db", image: "docker.io/library/postgres:16-alpine", state: .running, ip: "192.168.64.40",
                cmd: ["postgres"], labels: [AppLabel.project: "acdemo"], memory: 2 << 30,
                mounts: [volumeMount("pgdata", at: "/var/lib/postgresql/data")],
                env: ["POSTGRES_DB=acdemo", "POSTGRES_USER=acdemo", "PGDATA=/var/lib/postgresql/data"]),
            make(
                "api", image: "docker.io/library/acdemo-api:latest", state: .running, ip: "192.168.64.41",
                ports: [.init(hostPort: 18081, containerPort: 8080)], cmd: ["uvicorn", "app:app", "--port", "8080"],
                labels: [AppLabel.project: "acdemo"], env: ["DATABASE_URL=postgres://db.test:5432/acdemo"]),
            make(
                "cache", image: "docker.io/library/redis:7-alpine", state: .running, ip: "192.168.64.42",
                cmd: ["redis-server", "--appendonly", "yes"], labels: [AppLabel.project: "acdemo"], memory: 512 << 20,
                mounts: [volumeMount("cache-data", at: "/data")]),
            make(
                "old-job", image: "docker.io/library/alpine:latest", state: .stopped, ip: "",
                cmd: ["sh", "-c", "echo done"]),
        ]
    }

    static func volumeMount(_ name: String, at destination: String) -> Container.Mount {
        Container.Mount(
            destination: destination,
            source: "/Users/you/Library/Application Support/com.apple.container/volumes/\(name)/volume.img",
            type: .volume(name: name, format: "ext4"))
    }

    /// A stable, realistic-looking 64-hex digest for sample data (FNV-1a stretched over the seed).
    static func fakeDigest(_ seed: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        var out = ""
        while out.count < 64 {
            for b in (seed + String(out.count)).utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
            out += String(h, radix: 16).leftPadded(to: 16)
        }
        return String(out.prefix(64))
    }

    /// Plausible application logs per sample container (postgres, redis, uvicorn, generic HTTP).
    static func sampleLogs(for id: String, count: Int) -> [String] {
        func ts(_ i: Int) -> String {
            "2026-10-19 15:\(String(format: "%02d", 40 + i / 60)):\(String(format: "%02d", i % 60))"
        }
        switch id {
        case "db":
            let boot = [
                "PostgreSQL init process complete; ready for start up.",
                "\(ts(0)).112 UTC [1] LOG:  starting PostgreSQL 16.4 on aarch64-unknown-linux-musl",
                "\(ts(0)).113 UTC [1] LOG:  listening on IPv4 address \"0.0.0.0\", port 5432",
                "\(ts(0)).113 UTC [1] LOG:  listening on IPv6 address \"::\", port 5432",
                "\(ts(0)).118 UTC [1] LOG:  listening on Unix socket \"/var/run/postgresql/.s.PGSQL.5432\"",
                "\(ts(1)).004 UTC [48] LOG:  database system was shut down at \(ts(0)) UTC",
                "\(ts(1)).011 UTC [1] LOG:  database system is ready to accept connections",
            ]
            let steady = (2..<max(count, 8)).map { i -> String in
                switch i % 5 {
                case 0:
                    return
                        "\(ts(i)).201 UTC [\(60 + i)] LOG:  connection received: host=192.168.64.41 port=\(40_000 + i * 7)"
                case 1: return "\(ts(i)).203 UTC [\(60 + i)] LOG:  connection authorized: user=acdemo database=acdemo"
                case 2:
                    return
                        "\(ts(i)).540 UTC [\(60 + i)] LOG:  duration: \(3 + i % 9).\(i % 10)12 ms  statement: SELECT * FROM items WHERE id = $1"
                case 3: return "\(ts(i)).902 UTC [55] LOG:  checkpoint starting: time"
                default:
                    return
                        "\(ts(i)).990 UTC [55] LOG:  checkpoint complete: wrote \(10 + i % 40) buffers (0.1%); write=\(i % 3).1 s"
                }
            }
            return Array((boot + steady).prefix(count))
        case "cache":
            let boot = [
                "1:C 19 Oct 2026 15:40:00.010 * oO0OoO0OoO0Oo Redis is starting oO0OoO0OoO0Oo",
                "1:C 19 Oct 2026 15:40:00.010 * Redis version=7.4.1, bits=64, commit=00000000, modified=0, pid=1",
                "1:M 19 Oct 2026 15:40:00.012 * Running mode=standalone, port=6379.",
                "1:M 19 Oct 2026 15:40:00.013 * Server initialized",
                "1:M 19 Oct 2026 15:40:00.013 * Ready to accept connections tcp",
            ]
            let steady = (0..<max(count, 6)).map { i in
                "1:M 19 Oct 2026 15:\(String(format: "%02d", 41 + i / 60)):\(String(format: "%02d", i % 60)).000 * 100 changes in 300 seconds. Saving..."
            }
            return Array((boot + steady).prefix(count))
        case "api":
            let boot = [
                "INFO:     Started server process [1]", "INFO:     Waiting for application startup.",
                "INFO:     Application startup complete.",
                "INFO:     Uvicorn running on http://0.0.0.0:8080 (Press CTRL+C to quit)",
            ]
            let paths = ["/health", "/items", "/items/42", "/items?limit=20", "/users/me", "/items/7"]
            let steady = (0..<max(count, 6)).map { i in
                "INFO:     192.168.64.1:\(50_000 + i * 3) - \"GET \(paths[i % paths.count]) HTTP/1.1\" \(i % 11 == 10 ? "404 Not Found" : "200 OK")"
            }
            return Array((boot + steady).prefix(count))
        default:
            return (0..<count).map {
                "192.168.64.1 - - [19/Oct/2026 15:\(String(format: "%02d", 40 + $0 / 60)):\(String(format: "%02d", $0 % 60))] \"GET /item/\($0) HTTP/1.1\" \($0 % 7 == 0 ? 404 : 200) -"
            }
        }
    }
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: "0", count: width - count) + self
    }
}
