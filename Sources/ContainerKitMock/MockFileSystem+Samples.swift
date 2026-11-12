import ContainerKit
import Foundation

// Believable sample filesystems for the mock containers (an Alpine-like base plus what each image adds).

extension MockFileSystem {
    /// The filesystem a sample container would plausibly have, chosen by its image.
    public static func sample(for container: Container) -> MockFileSystem {
        var fs = alpineBase(hostname: container.id)
        let image = container.imageReference
        if image.contains("postgres") {
            fs.addPostgres()
        } else if image.contains("redis") {
            fs.addRedis()
        } else if image.contains("python") || image.contains("acdemo-api") {
            fs.addPythonApp()
        }
        // Mount points always exist, even on an image this file knows nothing about.
        for mount in container.configuration.mounts where !fs.exists(ContainerPath.normalize(mount.destination)) {
            fs.directory(mount.destination, daysOld: 3)
        }
        return fs
    }

    static func alpineBase(hostname: String) -> MockFileSystem {
        var fs = MockFileSystem()
        for path in ["/dev", "/home", "/media", "/mnt", "/opt", "/proc", "/run", "/srv", "/sys"] {
            fs.directory(path, daysOld: 40)
        }
        fs.directory("/root", mode: 0o700, daysOld: 40)
        fs.directory("/tmp", mode: 0o1777, daysOld: 0.02)
        fs.file("/bin/busybox", size: 919_760, mode: 0o755, daysOld: 60)
        for tool in ["ash", "cat", "ls", "mkdir", "mv", "rm", "sh", "stat"] {
            fs.link("/bin/\(tool)", to: "/bin/busybox")
        }
        fs.file("/sbin/apk", size: 67_688, mode: 0o755, daysOld: 60)
        fs.file("/lib/ld-musl-aarch64.so.1", size: 723_480, mode: 0o755, daysOld: 60)
        fs.link("/lib/libc.musl-aarch64.so.1", to: "ld-musl-aarch64.so.1")
        fs.file("/etc/alpine-release", "3.22.1\n", daysOld: 60)
        fs.file("/etc/hostname", "\(hostname)\n", daysOld: 0.02)
        fs.file(
            "/etc/hosts", "127.0.0.1\tlocalhost\n::1\tlocalhost\n192.168.64.40\t\(hostname).test \(hostname)\n",
            daysOld: 0.02)
        fs.file("/etc/resolv.conf", "nameserver 192.168.64.1\nsearch test\n", daysOld: 0.02)
        fs.file(
            "/etc/os-release",
            """
            NAME="Alpine Linux"
            ID=alpine
            VERSION_ID=3.22.1
            PRETTY_NAME="Alpine Linux v3.22"
            HOME_URL="https://alpinelinux.org/"

            """, daysOld: 60)
        fs.file(
            "/etc/passwd",
            """
            root:x:0:0:root:/root:/bin/sh
            daemon:x:2:2:daemon:/sbin:/sbin/nologin
            nobody:x:65534:65534:nobody:/:/sbin/nologin

            """, daysOld: 60)
        fs.file("/etc/group", "root:x:0:root\ndaemon:x:2:root,bin,daemon\nnobody:x:65534:\n", daysOld: 60)
        fs.file("/etc/shadow", "root:*::0:::::\n", mode: 0o640, daysOld: 60)
        fs.file("/etc/apk/repositories", "https://dl-cdn.alpinelinux.org/alpine/v3.22/main\n", daysOld: 60)
        fs.file("/etc/ssl/certs/ca-certificates.crt", size: 219_342, daysOld: 60)
        fs.link("/etc/ssl/cert.pem", to: "certs/ca-certificates.crt")
        fs.link("/etc/mtab", to: "../proc/mounts")
        for path in ["/usr/bin", "/usr/lib", "/usr/local/bin", "/usr/local/lib", "/usr/sbin", "/usr/share"] {
            fs.directory(path, daysOld: 60)
        }
        fs.file("/usr/bin/env", size: 14_120, mode: 0o755, daysOld: 60)
        for path in ["/var/cache", "/var/lib", "/var/log", "/var/tmp"] { fs.directory(path, daysOld: 40) }
        fs.link("/var/run", to: "/run")
        fs.file("/root/.ash_history", "ls -la /\ncat /etc/os-release\n", mode: 0o600, daysOld: 0.5)
        fs.file("/.dockerenv", "", daysOld: 0.02)
        return fs
    }

    mutating func addPostgres() {
        let data = "/var/lib/postgresql/data"
        directory("/var/lib/postgresql", owner: "postgres", uid: 70, daysOld: 12)
        directory(data, mode: 0o700, owner: "postgres", uid: 70, daysOld: 0.02)
        for name in ["base", "global", "pg_wal", "pg_stat", "pg_tblspc", "pg_xact"] {
            directory("\(data)/\(name)", mode: 0o700, owner: "postgres", uid: 70, daysOld: 0.05)
        }
        file("\(data)/PG_VERSION", "16\n", mode: 0o600, owner: "postgres", uid: 70, daysOld: 12)
        file(
            "\(data)/postgresql.conf",
            """
            # PostgreSQL configuration file
            listen_addresses = '*'
            max_connections = 100
            shared_buffers = 128MB
            dynamic_shared_memory_type = posix
            log_timezone = 'UTC'
            datestyle = 'iso, mdy'

            """, mode: 0o600, owner: "postgres", uid: 70, daysOld: 12)
        file(
            "\(data)/pg_hba.conf",
            "# TYPE  DATABASE  USER  ADDRESS       METHOD\nlocal   all       all                 trust\n"
                + "host    all       all   all           scram-sha-256\n", mode: 0o600, owner: "postgres", uid: 70,
            daysOld: 12)
        file(
            "\(data)/postmaster.pid", "1\n\(data)\n1760888400\n5432\n", mode: 0o600, owner: "postgres", uid: 70,
            daysOld: 0.02)
        file(
            "\(data)/pg_wal/000000010000000000000001", size: 16_777_216, mode: 0o600, owner: "postgres", uid: 70,
            daysOld: 0.01)
        file("\(data)/base/16384/2619", size: 122_880, mode: 0o600, owner: "postgres", uid: 70, daysOld: 0.05)
        file("/usr/local/bin/postgres", size: 9_812_344, mode: 0o755, daysOld: 20)
        file("/usr/local/bin/psql", size: 712_360, mode: 0o755, daysOld: 20)
        file(
            "/usr/local/bin/docker-entrypoint.sh", "#!/usr/bin/env bash\nset -Eeo pipefail\nexec \"$@\"\n", mode: 0o755,
            daysOld: 20)
        directory("/docker-entrypoint-initdb.d", daysOld: 20)
        directory("/run/postgresql", mode: 0o3775, owner: "postgres", uid: 70, daysOld: 0.02)
    }

    mutating func addRedis() {
        directory("/data", owner: "redis", uid: 999, daysOld: 0.01)
        file(
            "/data/dump.rdb",
            data: Data([0x52, 0x45, 0x44, 0x49, 0x53, 0x30, 0x30, 0x31, 0x32, 0xFA, 0x00, 0x09, 0xFF]),
            size: 48_211, owner: "redis", uid: 999, daysOld: 0.004)
        file("/data/appendonlydir/appendonly.aof.1.base.rdb", size: 88, owner: "redis", uid: 999, daysOld: 2)
        file(
            "/data/appendonlydir/appendonly.aof.1.incr.aof", "*2\r\n$6\r\nSELECT\r\n$1\r\n0\r\n", owner: "redis",
            uid: 999, daysOld: 0.004)
        file(
            "/data/appendonlydir/appendonly.aof.manifest", "file appendonly.aof.1.base.rdb seq 1 type b\n",
            owner: "redis", uid: 999, daysOld: 2)
        file("/usr/local/bin/redis-server", size: 12_614_792, mode: 0o755, daysOld: 25)
        file("/usr/local/bin/redis-cli", size: 6_921_304, mode: 0o755, daysOld: 25)
        link("/usr/local/bin/redis-sentinel", to: "redis-server")
        file("/usr/local/bin/docker-entrypoint.sh", "#!/bin/sh\nset -e\nexec \"$@\"\n", mode: 0o755, daysOld: 25)
    }

    mutating func addPythonApp() {
        file(
            "/app/app.py",
            """
            from fastapi import FastAPI

            app = FastAPI(title="acdemo")


            @app.get("/health")
            def health() -> dict[str, str]:
                return {"status": "ok"}


            @app.get("/items/{item_id}")
            def item(item_id: int) -> dict[str, int]:
                return {"id": item_id}

            """, daysOld: 2)
        file(
            "/app/requirements.txt", "fastapi==0.118.0\nuvicorn[standard]==0.37.0\npsycopg[binary]==3.2.10\n",
            daysOld: 6)
        file("/app/README.md", "# acdemo API\n\nRun with `uvicorn app:app --port 8080`.\n", daysOld: 6)
        file("/app/.env", "APP_ENV=dev\nLOG_LEVEL=info\n", mode: 0o600, daysOld: 2)
        file("/app/release notes.txt", "1.4.0\n- faster item lookups\n- health endpoint\n", daysOld: 1)
        file("/app/docs/café menu — naïve.md", "| item | price |\n|---|---|\n| espresso | 2.50 |\n", daysOld: 9)
        file(
            "/app/static/logo.png",
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]
            ),
            size: 18_342, daysOld: 9)
        file(
            "/app/__pycache__/app.cpython-313.pyc", data: Data([0xF3, 0x0D, 0x0D, 0x0A, 0x00, 0x00]), size: 1_204,
            daysOld: 0.02)
        link("/app/current", to: "/app/static")
        // A directory larger than the listing limit, to show truncation.
        directory("/app/data/events", daysOld: 0.01)
        for index in 1...2_400 {
            let name = "event-" + String(repeating: "0", count: 5 - String(index).count) + String(index) + ".json"
            file("/app/data/events/\(name)", "{\"id\":\(index),\"type\":\"view\"}\n", daysOld: Double(index) / 2_400)
        }
        file("/usr/local/bin/python3.13", size: 5_921_112, mode: 0o755, daysOld: 20)
        link("/usr/local/bin/python3", to: "python3.13")
        link("/usr/local/bin/python", to: "python3")
        file(
            "/usr/local/bin/uvicorn", "#!/usr/local/bin/python3\nfrom uvicorn.main import main\nmain()\n", mode: 0o755,
            daysOld: 6)
        directory("/usr/local/lib/python3.13/site-packages", daysOld: 6)
    }
}
