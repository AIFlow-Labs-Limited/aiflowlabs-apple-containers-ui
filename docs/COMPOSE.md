# Compose file import

Apple's `container` has no `compose` command. Container Desktop reads a `compose.yaml` / `docker-compose.yml`,
shows what it would do, and then runs the equivalent `container …` commands one after another.

It is an importer for a defined subset, not a reimplementation of Docker Compose. Everything outside the subset is
listed in the preview before anything runs.

Last verified on 2026-11-12 against a running `container` CLI 1.5.0 engine: see
[Verified on a live engine](#verified-on-a-live-engine) and
[What has not been verified](#what-has-not-been-verified).

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
5. Before a service whose dependency must be healthy or finished (`depends_on` with `condition:`), the run waits:
   it runs the dependency's health check inside its container until it passes, or waits for the dependency to
   stop. The wait is its own step with a live status ("Waiting for db to be healthy (attempt 3)"). See
   [Health checks and waiting](#health-checks-and-waiting).

A network or volume that already exists is reused and not touched. A container whose name already exists blocks
the run until you tick **Replace existing container…**; that deletes it (killing it if it is running) and creates
it again, after a confirmation that names it.

Every container gets the labels `io.aiflowlabs.containerdesktop.project=<project>` (what the Containers list
groups by), `com.docker.compose.project=<project>` and `com.docker.compose.service=<service>`. Networks and
volumes the import creates get the project labels too. A service with `restart:` also gets
`io.aiflowlabs.containerdesktop.restart=<policy>`, which is what the app's restart supervisor reads.

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
| `env_file` (string, list, `{path, required}`) | `--env-file`, or `-e` per variable | A missing required file blocks the run; `required: false` files are skipped when missing. Later files win over earlier ones and `environment:` wins over both. `container run --env-file` takes lines literally (quotes and trailing `# comments` stay in the value, `export KEY=…` is refused), so when a file has such lines the service's env-file variables are read the Compose way and passed as `-e`, with a note in the preview. Variables inside env-file values are not expanded. |
| `ports` (short and long syntax, ranges, IPv6 host) | `-p [ip:]host:container/proto` | tcp and udp. A port without a host port is published on the same number (Docker would pick a random one). |
| `volumes` (short and long syntax) | `-v` / `--tmpfs` | Named volumes, bind mounts (`./relative`, `~/home`, absolute), `:ro`, anonymous volumes, `type: tmpfs` with `size`. |
| `tmpfs` | `--tmpfs` | |
| `networks` (list or map) | `--network` (repeated) | Only with "Networks from the file". |
| `depends_on` (list or map) | start order, plus a wait step per condition | `service_started` (default), `service_healthy` and `service_completed_successfully`. `restart:` and `required:` inside an entry are ignored. See [Health checks and waiting](#health-checks-and-waiting). |
| `healthcheck` (`test` as `CMD`, `CMD-SHELL`, string or `NONE`; `interval`, `timeout`, `retries`, `start_period`, `start_interval`; `disable`) | run by the app with `container exec` | Only while another service waits for it during the import. Compose's defaults and duration syntax (`1m30s`, `500ms`). |
| `restart` (`no`, `always`, `unless-stopped`, `on-failure`, `on-failure:N`) | label `io.aiflowlabs.containerdesktop.restart` | Enforced by Container Desktop while it is running, not by the runtime. See [Restart policies](#restart-policies). |
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
| A `healthcheck` without `test:` | Docker would use the image's own `HEALTHCHECK`; this runtime does not read it, so the service has no health check. |
| `deploy` beyond `resources.limits.cpus/memory` (`replicas`, `update_config`, `restart_policy`, `reservations`, GPUs, …) | Orchestrator settings; one container per service. Use the service-level `restart:` for a restart policy. |
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

## Health checks and waiting

Apple's runtime has no health checks (`container run --help` on CLI 1.5.0 has no `--health-*` option, and
`container inspect` reports no health). Container Desktop therefore runs the check itself, and only where it
decides something: while a service waits for another one.

- **`condition: service_healthy`**: after the dependency has been started, the run executes its
  `healthcheck.test` inside the container (`container exec`; exit code 0 means healthy), again and again until it
  passes, and only then starts the dependent service. `CMD` runs the words as they are, `CMD-SHELL` and the string
  form run through `/bin/sh -c`.
- **Timing** follows Compose: a probe that takes longer than `timeout` counts as failed; after `retries` failures
  in a row the dependency is unhealthy and the run stops at that step, like any failed step, with the last probe's
  output and the exact command; failures during `start_period` do not count, and probes in that period are
  `start_interval` apart. Defaults: `interval` 30 s, `timeout` 30 s, `retries` 3, `start_period` 0 s,
  `start_interval` 5 s.
- **`condition: service_completed_successfully`**: the run waits until the dependency's container has stopped.
- A dependency with `service_healthy` but no usable health check (none, `disable: true`, `test: ["NONE"]`) blocks
  the run, as it does in Docker Compose.
- **Stop** in the run sheet (or cancelling the task in the Activity window) ends a wait at once.
- The preview shows each service's health check and what it waits for, and the wait appears in the command list
  as the equivalent shell loop.

Differences from Docker Compose:

| | Docker Compose | Container Desktop |
|---|---|---|
| Who runs the check | The engine, for the container's whole life | The app, during the import run only. Nothing watches the container afterwards, and no health status is shown in the Containers list. |
| A check nobody waits for | Runs anyway | Is not run; the preview says so. |
| First probe | One `interval` after the start | At once. That extra probe does not count towards `retries`, so a container is declared unhealthy no earlier than Docker would. In practice a stack with `interval: 30s` comes up sooner. |
| `service_completed_successfully` | Requires exit code 0 | Any exit counts: `container inspect` on a stopped container has no exit code on CLI 1.5.0 (only `"state": "stopped"`). The preview says so. |
| A dependency that exits while it is waited for | Fails | Fails at the next probe: "stopped before it became healthy". |
| `depends_on.<service>.restart` / `.required` | Honoured | Ignored. |
| Image `HEALTHCHECK` | Used when the service has none | Not read. |

## Restart policies

Apple's runtime has no restart policies either (`container run` and `container create` on CLI 1.5.0 have no
`--restart`). Container Desktop provides them itself:

- The policy is stored on the container as the label `io.aiflowlabs.containerdesktop.restart`
  (`always`, `unless-stopped`, `on-failure` or `on-failure:5`). `restart:` in a compose file sets it, and so does
  the **Restart policy** picker in the Run sheet. CLI 1.5.0 has no command that changes the labels of an existing
  container, so the policy is fixed when the container is created; to change it, create the container again.
- While the app is running it watches the Containers list (the same polling that keeps the list fresh; every
  10 s when no window shows it). A container with a policy that is found stopped, and was not stopped from the
  app, is started again: after 1 s, then 2 s, 4 s … up to 60 s between attempts. The count starts over once the
  container has stayed up for 30 s. `on-failure:N` gives up after N attempts in a row; `always` and
  `unless-stopped` keep trying once a minute.
- **Stop, Kill, Stop All and Delete in the app are respected**, also across a relaunch of the app: such a
  container stays stopped. `unless-stopped` stays stopped until you start it again; `always` is started again the
  next time the app launches or the container system starts, as in Docker.
- **When the app launches, and when the container system comes up**, stopped containers with `always` are
  started, and `unless-stopped` ones that were not stopped from the app. This is what brings a stack back after a
  reboot, provided the app starts with the Mac: switch on *Launch Container Desktop at login* and *Start the
  container system when the app launches* under Settings › General.
- Every restart is an entry in the Activity window and a toast ("Restart db, attempt 2"); the container's
  Inspect tab shows the policy and the number of restarts since the app was opened.
- **Settings › General › Enforce restart policies** turns all of it off.
- **Settings › General › Keep enforcing when Container Desktop is closed** (off by default) installs a small
  background helper, so the policies are also enforced after you quit the app. See
  [The background helper](#the-background-helper).
- A container without the label is never started by the app.

What differs from Docker, and cannot be fixed from the app:

| | Docker | Container Desktop |
|---|---|---|
| Who enforces it | The daemon, always | The app while it is running (its window can be closed; the menu bar item is enough). After you quit it, nothing is restarted unless the optional background helper is switched on. |
| `container stop` in a terminal | Respected like any stop | Cannot be told apart from a crash: the container is started again. Stop it from the app, or delete it. |
| `on-failure` | Restarts on a non-zero exit code only | The runtime reports no exit code, so it restarts whenever the container stops without the app having stopped it, also after a clean exit. Not started on launch. |
| Delay before a restart | 100 ms, doubling, up to 1 minute; reset after 10 s of uptime | 1 s, doubling, up to 1 minute; reset after 30 s of uptime. The restart happens at the next look at the list: a few seconds with a window open, up to about 10 s more without. |
| `always` after a manual stop | Comes back when the daemon restarts | Comes back when the app is launched or the container system starts (with the helper: when the helper starts, which is at login, or the container system starts). |
| Restart count | Kept by the engine | Counted since the app was opened. Restarts made by the helper are not counted in the app. |
| After a reboot | The daemon starts and brings the containers back | Something has to start the container system first: you, or the app with *Launch at login* and *Start the container system when the app launches*. The helper waits for it and does not start it. |
| Changing the policy | `docker update --restart` | Not possible; recreate the container. |
| With `--rm` | Refused | Refused in the Run sheet. |

### The background helper

Without it, restart policies stop being enforced the moment you quit Container Desktop. With **Settings › General ›
Keep enforcing when Container Desktop is closed** switched on:

- A per-user LaunchAgent (`~/Library/LaunchAgents/io.aiflowlabs.containerdesktop.supervisor.plist`) runs the
  app's own executable with `--supervise`: no window, no Dock icon, no menu bar item. launchd starts it when you
  switch it on and at every login, and starts it again if it crashes. Switching the setting off stops it and
  removes the file.
- It applies the same rules as the app (same delays, same limits), reading the container list every 10 s while
  at least one container has a policy and every 30 s otherwise. When a restart is due it wakes up for it, so a
  container that stops is typically running again within about 15 s.
- **Exactly one of the two enforces.** While the helper is alive the app stands down and only records what you
  do; when the helper goes away (switched off, or it crashed) the app takes over at its next look. The hand-over
  uses file locks that the system releases when a process ends, so the two can never both restart a container.
  A change of hands is not treated as a launch: what you stopped stays stopped, also with `always`.
- **Stops made in the app are respected by the helper.** The app writes them to
  `~/Library/Application Support/Container Desktop/Supervision/state.json` (container names and timestamps
  only), which the helper reads before every look. The same goes for stopping the container system from the app.
- It **waits for the container system and never starts it**. While the system is not running, or the `container`
  CLI is missing, it checks again every 20 to 30 s and does nothing else.
- Its restarts are not in the Activity window. They are in the system log:
  `log show --last 1h --predicate 'subsystem == "io.aiflowlabs.containerdesktop" AND category == "supervisor"'`.
  The log holds container names and CLI error messages, never environment variables or commands.
- "Enforce restart policies" switched off makes the helper idle as well.
- After an update or after moving the app, opening Container Desktop once re-installs the helper for the new
  copy. Until then the old helper process keeps running.
- From a terminal: `"/Applications/Container Desktop.app/Contents/MacOS/ContainerDesktop"
  --background-supervision status` (or `register` / `unregister`).

What the helper does not change: a `container stop` typed in a terminal still looks like a crash and is undone,
`on-failure` still reacts to every unexpected stop (no exit codes), and the policy is still fixed when the
container is created.

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
| `default` network, DNS domain set and registered (`container system dns list` shows it, for example `test`) | `db` and `db.test` resolve. *Not re-checked in the 2026-11-12 pass: registering a domain needs `sudo`.* |
| `default` network, DNS domain set as a property (`dns.domain`) but not registered | Names do not resolve (`NXDOMAIN`), although `/etc/resolv.conf` in the container says `domain test`. IP address only. *Observed 2026-11-12.* |
| `default` network, no DNS domain | Names do not resolve. Use the IP address, or set a domain under Settings › Network. |
| A network created with `container network create` | Names do not resolve ([apple/container#1809](https://github.com/apple/container/issues/1809)). IP address only. *Observed 2026-11-12.* |

The preview reads the engine's DNS domain, whether that domain is registered, and the existing resources, and
words its summary accordingly; when the engine is stopped it says the DNS setup could not be checked. It never
rewrites your environment variables.

From the Mac, `db.test` needs the domain registered with macOS as well (Settings › Network › Enable DNS names,
which runs `sudo container system dns create`). Published ports (`ports:`) are reachable on `localhost` either way.

## Things that commonly surprise

- **Memory:** a container without `mem_limit` gets the engine default (1 GB unless changed under
  Settings › Resources). Databases often need more.
- **PostgreSQL on a named volume:** named volumes are ext4 disks with a `lost+found` folder at the top, which makes
  `initdb` refuse `/var/lib/postgresql/data`. The preview adds a note; set
  `PGDATA=/var/lib/postgresql/data/pgdata`.
- **Missing bind-mount folders:** Docker creates them; this runtime refuses to start the container
  (`path '…' does not exist`). The preview warns; create them first.
- **`host.docker.internal`** does not exist. Settings › Network has the `host.container.internal` helper.

## Verified on a live engine

Run on 2026-11-12 against a running engine, `container` CLI 1.5.0, through the app's real backend
(`Tests/AppCoreTests/ComposeIntegrationTests.swift` and `ComposeBuildIntegrationTests.swift`;
`CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`).
The Mac had `dns.domain = "test"` set as an engine property and no registered DNS domain.

| What | Observed |
|---|---|
| A project with two services from local images, a named volume, a published port, environment variables, a bind mount, `working_dir`, `depends_on` and labels | Planned as *create volume, run dependency, run dependent* with no pull. Both containers run and carry `io.aiflowlabs.containerdesktop.project`, `com.docker.compose.project` and `com.docker.compose.service`; the volume carries the project label. The environment variable, the volume, the bind mount (read and write, visible on the Mac) and the working directory are there. Redis answers on `localhost:<published port>`. "Remove What Was Created" removes the containers and the volume. |
| `tmpfs` with `size: 16m` → `--tmpfs /scratch:size=16M` | Works: `tmpfs … size=16384k`. Without a size the tmpfs is about half the container's memory. |
| One service on two networks → `--network a --network b` | Works: the container gets `eth0` and `eth1`, one address per network. The built-in `default` network plus a created one also works. |
| A bind mount whose host folder is missing | `container run` exits 1 with `Error: path '<absolute path>' does not exist`. No container is left behind and the folder is not created. The run stops at that step. |
| `entrypoint:` without `command:` → `--entrypoint X` and no arguments | The image's default command is dropped, as in Docker (`redis:7-alpine` with `--entrypoint /bin/hostname` runs `hostname` alone). `--entrypoint "echo hi"` is looked up as one executable and fails, so passing only the first word is right. |
| Names between containers, no registered DNS domain | On the `default` network and on a created network: the name does not resolve (`NXDOMAIN`), the IP address works. The preview said so in both cases. |
| A second import of the same file | Blocked: both container names are reported as existing, the volume as reused. |
| `build:` with `context`, `dockerfile`, `target` and `args` (a three-stage Dockerfile `FROM docker.io/library/alpine:latest` with `ARG`, `RUN` and `COPY`) | Built by the existing builder container as `<project>-<service>:latest` and run. The build argument, the copied file and the chosen stage are in the container; the later stage is not. The builder is started when it is stopped and is left running. |
| `env_file`, string and list form, with a comment line, a blank line, a value with spaces, `a=b=c`, and `café 한` | Values arrive byte for byte. A later file wins over an earlier one, `environment:` wins over both, a missing `required: false` file is skipped. |
| An env file with `"double"` and `'single'` quotes, `value # comment` and `export KEY=…` | `container run --env-file` alone keeps the quotes and the comment in the value and refuses `export` (`variable 'export KEY' contains whitespaces`) and `KEY = value`; a key without `=` is dropped. Through the app the values arrive as Compose would read them (see the bug below). |
| `cpus: 2` + `mem_limit: 512m`; `deploy.resources.limits` with `cpus: "1.5"` + `memory: 300M` | `container inspect` reports 2 CPUs / 512 MiB and 2 CPUs (rounded up, with a note) / 300 MiB. Inside, the VM shows a little more than the limit (`-c 2 -m 512M`: `nproc` 3, about 600 MB). |
| A service with `profiles: [debug]` | Not planned and not started by default; planned once the profile is ticked. |
| An image that is not local (`docker.io/library/busybox:1.36`) | Planned as a pull step, pulled from Docker Hub, run; a second look at the engine no longer plans a pull. |
| A run whose second of three containers cannot start (missing bind-mount folder) | Stops at that step: first two steps succeeded, the third failed with the CLI's message, the fourth is skipped. The output names what was left in place. "Remove What Was Created" removes the container and the volume the run created and leaves a volume that existed before. |

Health checks and restart policies, same day and engine
(`ComposeHealthIntegrationTests.swift`, `RestartPolicyIntegrationTests.swift`):

| What | Observed |
|---|---|
| `app` depends on `cache` with `condition: service_healthy`; `cache` is `redis:7-alpine` started as `sh -c "sleep 4; exec redis-server"` with `test: ["CMD", "redis-cli", "ping"]`, `interval: 1s` | Planned as *run cache, wait for cache to be healthy, run app*. The first probes fail with exit code 1 (connection refused), a later one passes, `redis-cli ping` answers `PONG`, and `app` was started at least 4 s after `cache`. |
| A dependency whose check never passes (`CMD-SHELL` `echo not ready >&2; exit 3`, `interval: 500ms`, `retries: 2`) | The run stops at the wait step after two counted failures with "did not become healthy … (last result: exit code 3: not ready)" and the exact `container exec` command. The dependent is never started; "Remove What Was Created" removes the dependency. |
| `condition: service_completed_successfully` on a job that runs `sh -c "sleep 3; exit 7"` | The dependent starts once the job has stopped (3 s later). `container inspect` of the stopped job has `"state": "stopped"` and no exit code, so the non-zero exit goes unnoticed, as the preview warns. |
| `restart: unless-stopped` in the file | The container carries `io.aiflowlabs.containerdesktop.restart=unless-stopped`. |
| A container with `always` that runs `sh -c 'sleep 2; exit 1'` | Started again by the supervisor each time it exits, with a longer pause each time (three restarts within about 15 s). A stopped container keeps its `startedDate`, which is how an exit between two looks is noticed. |
| Containers with `always` and `unless-stopped`, stopped the way the app's Stop does it | Both stay stopped. A second supervisor with the same stored state (an app relaunch) starts the `always` one and leaves the `unless-stopped` one stopped. |
| `on-failure:2` on a container that always exits | Restarted twice, then left stopped; nothing more happens. |
| A crashing container without the label | Never started. |
| The whole path in the app (compose file with `restart: always` → run → Containers polling → supervisor) | Restarted twice with Activity entries "Restart …, attempt 1/2". After Stop through the Containers store it stays stopped. |

The background helper, 2026-11-12, with an ad-hoc signed `make app` build. By then the engine on the test Mac had
been upgraded, so these ran on **container 1.7.1** (CLI and server), not 1.5.0
(`BackgroundSupervisorIntegrationTests.swift` and by hand):

| What | Observed |
|---|---|
| Switching the helper on while the app is running | launchd runs `ContainerDesktop --supervise`. Its log: "Container Desktop is enforcing restart policies. Standing by.", and 11 s later "Enforcing restart policies (1 container with a policy)." The lock file that marks the enforcer moved from the app's process to the helper's. |
| App quit, then `container stop` on a container with `always` | Running again 8 s after the stop returned; the log has "Restart …, attempt 1". After `container kill`: running again 13 s later, "attempt 2". |
| A container stopped through the app's Containers store while the helper enforces | Left stopped for the 35 s it was watched; the mark was in `state.json` and was removed after the container was deleted. Before that, the same container, killed from the CLI, had been started again by the helper. |
| The helper while idle | 0.05 s of CPU time in its first minute with no supervised container, 0.11 s in 2 min 24 s with one; about 20 MB of memory. |
| The helper killed with `kill -9` | launchd started it again 10 s later, and it went back to enforcing. |
| Switching the helper off (`--background-supervision unregister`, and by hand with `launchctl bootout` + `rm`) | It logs "Background supervision stopped." and exits; the job and the property list are gone. |
| The app bundle replaced by a newer build while the helper is installed | The helper starts from the new build. Opening the app once replaces the helper (old one stopped, new one started 2 s later). |
| The same with `SMAppService.agent` (tried first) | Registered and ran on the first build. After the bundle was replaced, launchd refused to start it (`OS_REASON_CODESIGNING`) while the API still reported it enabled, and registering again did not repair it. That is why the helper is a plain LaunchAgent. |

Bugs this found:

- The preview used to promise name resolution whenever the engine property `dns.domain` was set. That is not
  enough. The domain must also be registered (`container system dns list`). The preview now checks both.
- Env files were handed to `--env-file` unread. A file written for Docker Compose with `PASSWORD="secret"` gave the
  container a password that includes the quotes, and one with `export` stopped the run. Such files are now read by
  the app and passed as `-e` options.

## What has not been verified

- Name resolution with a **registered** DNS domain (the first row of the table above). Registering one needs
  `sudo`, which the test run does not use. That row still rests on earlier manual testing on CLI 1.5.0.
- `build:` options beyond `context`, `dockerfile`, `target` and `args` (`platforms`, `no_cache`, `pull`, `labels`),
  a build that fails, and pulling with `platform:` or from a registry that needs a login.
- `user`, `platform`, `init`, `read_only`, `cap_add` / `cap_drop`, `shm_size`, `ulimits`, `dns*`, `mac_address`,
  network `ipam` subnets and `external` volumes or networks: their arguments are covered by unit tests against
  `container <command> --help` on 1.5.0, not by a run.
- Cancelling a run half-way (cancelling a health wait is covered by a unit test on the mock engine only), and
  replacing an existing container ("Replace existing container…").
- Health checks: `start_period` / `start_interval` and a probe that hangs past its `timeout` are unit-tested on
  the mock engine, not on a live one.
- Restart policies: the 60 s ceiling of the delay, the reset after 30 s of uptime, the app stopping and starting
  the container system, a real reboot with *Launch at login*, and the app left running for hours with its window
  closed. The logic is unit-tested with a fake clock; the screens (Run sheet picker, Inspect rows, Settings
  switch, the wait step's live status) were built and compiled but not looked at in a running app in this pass.
- The background helper: a real logout, login or reboot (it was loaded with `launchctl`, which is what login
  does, but nobody logged out); the container system being stopped or started under it (that would have stopped
  other containers on the test Mac; waiting and backoff are unit-tested on the mock engine); the helper running
  for days; how it is listed under System Settings › General › Login Items; the Settings switch itself (the
  service behind it was driven with `--background-supervision`); the helper on CLI 1.5.0 or 1.6.
- Anything on CLI 1.6 or 1.7.

## For contributors

| Piece | Where |
|---|---|
| YAML → `ComposeFile`, interpolation, warnings (no UI; the only code that uses Yams) | `Sources/ContainerKit/Compose/` |
| `ComposePlanner` (file + options + what exists → ordered `ComposePlan`), `ComposeRun` (execution), `ComposeWait` (health and completion waits), `ComposeImport` (sheet state), `ComposeLoader` | `Sources/AppCore/Compose/` |
| `RestartPolicy` (the label) and `RestartSupervisor` (enforcement, fed by the containers poller) | `Sources/ContainerKit/Models/RestartPolicy.swift`, `Sources/AppCore/RestartSupervisor.swift` |
| The background helper: its loop, the hand-over locks, the shared state file, the LaunchAgent, the `--supervise` entry point | `Sources/AppCore/Supervision/`, `Sources/ContainerDesktop/App/HeadlessSupervisor.swift` |
| Import sheet | `Sources/ContainerDesktop/Features/Compose/` |
| Sample files and tests | `Tests/ContainerKitTests/Resources/compose/`, `Compose*Tests.swift` in both test targets |

Services become `RunSpec` / `BuildSpec` and go through the existing `ContainerBackend` calls; there is no second
path to the CLI. To support a new key: read it in `ComposeParser+Service.swift` (unread keys become warnings
automatically), map it in `ComposePlanner+Service.swift`, add it to a sample file and to the table above.
