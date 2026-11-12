# Compose file import

Apple's `container` has no `compose` command. Container Desktop reads a `compose.yaml` / `docker-compose.yml`,
shows what it would do, and then runs the equivalent `container …` commands one after another.

It is an importer for a defined subset, not a reimplementation of Docker Compose. Everything outside the subset is
listed in the preview before anything runs.

Last verified against `container` CLI 1.5.0 (`--help` output). The engine was not running while this was written;
see [What has not been verified](#what-has-not-been-verified).

## How to use it

- **File › Import Compose File…** (⇧⌘O), the stack button in the Containers toolbar, **Import Compose File…** in
  the command palette (⌘K), or drop a compose file (or the folder that contains one) on the main window.
- The preview shows: project name, services, variables, differences from Docker Compose, and the commands in the
  order they will run. Commands can be copied; secret-looking environment values are masked on screen.
- **Run** executes the commands as one task in the Activity window, with a state per step. It stops at the first
  failure, says what was created up to that point, and offers **Remove What Was Created…** (asks first; images are
  kept).
- After a successful run the Containers list opens with the project group selected. The group's menu has
  Start All / Stop All / Restart All / Delete All… (deleting asks first and keeps named volumes).

## What a run does, in order

1. `container network create` for each network (only with "Networks from the file", see below).
2. `container volume create` for each named volume a selected service uses.
3. `container image pull` for each image that is not available locally; `container build` for each service with
   `build:` (always, the builder cache makes repeats cheap).
4. `container run -d` for each service, dependencies first (`depends_on`), otherwise in file order.

A network or volume that already exists is reused and not touched. A container whose name already exists blocks
the run until you tick **Replace existing container…**; that deletes it (killing it if it is running) and creates
it again, after a confirmation that names it.

Every container gets the labels `io.aiflowlabs.containerdesktop.project=<project>` (what the Containers list
groups by), `com.docker.compose.project=<project>` and `com.docker.compose.service=<service>`. Networks and
volumes the import creates get the project labels too.

## Supported subset

### Top level

| Key | Support |
|---|---|
| `name` | Project name. Without it: the folder name, lowercased and reduced to letters, digits, `-`, `_`. Editable in the preview. |
| `services` | Yes (see below). |
| `volumes` | `name`, `external`, `labels`. Created as `<project>_<key>` unless `name:` is set. `external: true` must already exist (under `name:` or the key); the run is blocked if it does not. |
| `networks` | `name`, `external`, `labels`, first IPv4 and IPv6 `ipam.config[].subnet`. Only created with "Networks from the file". |
| `version` | Ignored (obsolete in Compose too). |
| `x-*` | Ignored; YAML anchors, aliases and `<<` merge keys work. |

### Services

| Key | Maps to | Notes |
|---|---|---|
| `image` | image argument | Pulled first when not local. |
| `build` (string, or `context`, `dockerfile`, `args`, `target`, `labels`, `platforms`, `no_cache`, `pull`) | `container build -t … -f … --build-arg … --target …` | Tag is `image:` when set, else `<project>-<service>:latest`. `dockerfile` resolves against the context. |
| `container_name` | `--name` | Wins over the naming option. |
| `command` (string or list) | arguments after the image | A string is split like a shell would. |
| `entrypoint` (string or list) | `--entrypoint` | The CLI takes one executable: the first word. Further words are placed before `command`. |
| `environment` (map or list) | `-e KEY=VALUE` | A key without a value becomes `-e KEY` (taken from the app's own environment, not your shell profile). |
| `env_file` (string, list, `{path, required}`) | `--env-file` | A missing required file blocks the run; `required: false` files are skipped when missing. |
| `ports` (short and long syntax, ranges, IPv6 host) | `-p [ip:]host:container/proto` | tcp and udp. A port without a host port is published on the same number (Docker would pick a random one). |
| `volumes` (short and long syntax) | `-v` / `--tmpfs` | Named volumes, bind mounts (`./relative`, `~/home`, absolute), `:ro`, anonymous volumes, `type: tmpfs` with `size`. |
| `tmpfs` | `--tmpfs` | |
| `networks` (list or map) | `--network` (repeated) | Only with "Networks from the file". |
| `depends_on` (list or map) | start order | Only "has been started" is honoured, see below. |
| `working_dir`, `user` | `-w`, `-u` | |
| `labels` (map or list) | `-l` | |
| `cpus`, `cpu_count`, `deploy.resources.limits.cpus` | `-c` | Whole CPUs only: fractions are rounded up, with a note. |
| `mem_limit`, `deploy.resources.limits.memory` | `-m` | Minimum 64 MB. |
| `platform` | `--platform` | Also used for the pull. |
| `init`, `read_only`, `tty`, `stdin_open` | `--init`, `--read-only`, `-t`, `-i` | |
| `dns`, `dns_search`, `dns_opt` | `--dns`, `--dns-search`, `--dns-option` | |
| `cap_add`, `cap_drop` | `--cap-add`, `--cap-drop` | |
| `shm_size`, `ulimits`, `mac_address` | `--shm-size`, `--ulimit`, `--network …,mac=` | |
| `profiles` | | Services with a profile are off until the profile is ticked in the preview. |
| `expose`, `attach`, `annotations` | | Accepted and ignored: every container port is reachable on the container's own IP anyway. |

Relative paths (bind mounts, build contexts, env files) resolve against the folder of the compose file.

### Variables

`$VAR`, `${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:?error}`, `${VAR?error}`, `${VAR:+value}`,
`${VAR+value}` and `$$`; defaults can contain variables. Values come from the `.env` file next to the compose
file and can be overridden per variable in the preview (the file is not changed).

Differences from Docker Compose: the process environment is **not** consulted (an app started from Finder does not
have your shell's variables), a variable with no value and no default becomes an empty string with a note, and a
missing `:?` variable stops the import until you type a value.

## Not supported

Each of these produces a warning in the preview, grouped per service; the stack still runs without them.

| Key | Why |
|---|---|
| `restart` (other than `"no"`) | The runtime has no restart policies. A container that exits, or the Mac rebooting, leaves it stopped. |
| `healthcheck` | The runtime runs no health checks. |
| `depends_on` conditions `service_healthy` / `service_completed_successfully` | Without health checks there is nothing to wait for: the dependency is started first and the dependent service right after. Services that need the database to be *ready* must retry on their own. |
| `deploy` beyond `resources.limits.cpus/memory` (`replicas`, `update_config`, `reservations`, GPUs, …) | Orchestrator settings; one container per service. |
| `secrets`, `configs` (service and top level) | No equivalent. |
| `extends`, `include`, override files, several `-f` files | One file is read as it is. `compose.override.yaml` next to it is detected and reported, not merged. |
| `links`, `external_links`, `extra_hosts`, `hostname`, `domainname` | The hostname is the container name; `/etc/hosts` cannot be edited from `container run`. |
| `network_mode` (`host` and others) | Every container is its own VM with its own IP; there is no host network. |
| `privileged` | Not in the CLI. Use `cap_add`. |
| Network `aliases`, `ipv4_address`, `ipv6_address` | `--network` on CLI 1.5.0 takes only `mac=` and `mtu=`. |
| Network `internal: true` | The CLI has `network create --internal`, the app does not pass it yet: the network is created as a normal one, with a warning. |
| Volume / network `driver`, `driver_opts` | One local driver each. |
| `devices`, `gpus`, `runtime`, `pid`, `ipc`, `security_opt`, `sysctls`, `logging`, `stop_signal`, `stop_grace_period`, `volumes_from`, `group_add`, `pull_policy`, `scale`, `develop` | No equivalent in `container run`. |
| Protocols other than tcp/udp in `ports`, host port ranges in the long syntax | Dropped with a warning. |
| Anything else | Reported as "not supported and is ignored". |

Not offered at all: `docker compose down -v`, `logs` for a whole project, `scale`, re-running only changed
services. "Down" is Stop All / Delete All… on the project group; volumes are deleted from the Volumes list.

## Names and networking

This is where the runtime differs most from Docker, so the preview states what applies to your Mac.

**A container's name is its hostname.** There are no network aliases on CLI 1.5.0, so a service is reachable under
the name of its container and nothing else. Two options in the preview follow from that:

- **Container names**
  - *Service names* (default): the container is called `db`. Other services' references to `db` in the file keep
    working. Container names are global, so a second project with a `db` service collides; the preview shows the
    collision and offers to replace the existing container.
  - *Project and service*: the container is called `<project>-db`. No collisions across projects, but `db` inside
    the file's connection strings no longer resolves; you have to use `<project>-db`.
- **Networks**
  - *Built-in default network* (default): nothing is created, every container joins the runtime's `default`
    network. The file's `networks:` are reported as not created.
  - *Networks from the file*: networks are created as `<project>_<name>` and services are attached as declared
    (services without `networks:` join `<project>_default`). This gives isolation, not discovery.

**When a name resolves (CLI 1.5.0):**

| Setup | From another container |
|---|---|
| `default` network, DNS domain configured (for example `test`) | `db` and `db.test` resolve. |
| `default` network, no DNS domain | Names do not resolve. Use the IP address, or set a domain under Settings › Network. |
| A network created with `container network create` | Names do not resolve ([apple/container#1809](https://github.com/apple/container/issues/1809)). IP address only. |

The preview reads the engine's DNS domain and existing resources and words its summary accordingly; when the
engine is stopped it says the DNS setup could not be checked. It never rewrites your environment variables.

From the Mac, `db.test` needs the domain registered with macOS as well (Settings › Network › Enable DNS names,
which runs `sudo container system dns create`). Published ports (`ports:`) are reachable on `localhost` either way.

## Things that commonly surprise

- **Memory:** a container without `mem_limit` gets the engine default (1 GB unless changed under
  Settings › Resources). Databases often need more.
- **PostgreSQL on a named volume:** named volumes are ext4 disks with a `lost+found` folder at the top, which makes
  `initdb` refuse `/var/lib/postgresql/data`. The preview adds a note; set
  `PGDATA=/var/lib/postgresql/data/pgdata`.
- **Missing bind-mount folders:** Docker creates them; the preview warns instead, create them first.
- **`host.docker.internal`** does not exist. Settings › Network has the `host.container.internal` helper.

## What has not been verified

The engine on the development Mac was stopped while this feature was built, so nothing was run against a real
runtime. The argument lists are covered by tests and match `container <command> --help` on 1.5.0. Not yet
confirmed on a live engine:

- the name-resolution table above (it comes from earlier manual testing on CLI 1.5.0 and the upstream issue, not
  from a run of this feature);
- `--tmpfs <path>:size=<n>` (the help only documents the path form);
- attaching one container to several networks by repeating `--network`;
- what `container run` does with a bind-mount source that does not exist;
- whether `--entrypoint` with no arguments keeps the image's default command (Docker clears it).

## For contributors

| Piece | Where |
|---|---|
| YAML → `ComposeFile`, interpolation, warnings (no UI; the only code that uses Yams) | `Sources/ContainerKit/Compose/` |
| `ComposePlanner` (file + options + what exists → ordered `ComposePlan`), `ComposeRun` (execution), `ComposeImport` (sheet state), `ComposeLoader` | `Sources/AppCore/Compose/` |
| Import sheet | `Sources/ContainerDesktop/Features/Compose/` |
| Sample files and tests | `Tests/ContainerKitTests/Resources/compose/`, `Compose*Tests.swift` in both test targets |

Services become `RunSpec` / `BuildSpec` and go through the existing `ContainerBackend` calls; there is no second
path to the CLI. To support a new key: read it in `ComposeParser+Service.swift` (unread keys become warnings
automatically), map it in `ComposePlanner+Service.swift`, add it to a sample file and to the table above.
