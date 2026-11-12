# Changelog

All notable changes to Container Desktop are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-11-12

### Added
- The Homebrew cask removes the macOS quarantine flag after the checksum check, so a Homebrew install opens on
  first launch without the Gatekeeper step.
- **Import Compose File** (File › Import Compose File…, ⇧⌘O; also in the Containers toolbar, the ⌘K palette, or drop
  a `compose.yaml` / `docker-compose.yml` on the window). Container Desktop reads the file, shows the services,
  volumes and networks it found, and lists the exact `container` commands it will run before anything starts.
  - Supports the common Compose keys: images and builds, ports, volumes and bind mounts, environment and env files,
    `depends_on` start order, resource limits, profiles, and `${VARIABLE}` values from the `.env` file next to the
    compose file (each can be overridden in the preview).
  - Everything Apple's runtime cannot do (secrets, host networking, override files, …) is listed
    per service in the preview instead of being silently dropped. See `docs/COMPOSE.md`.
  - The preview says which hostname services can use to reach each other on your setup, and warns when no DNS
    domain is configured.
  - Running a project shows progress per step. If a step fails, the run stops, says what was already created, and
    offers to remove it. Existing containers with the same name are never replaced without asking; existing
    volumes and networks are reused.
- **Restart policies.** Choose No, Always, Unless stopped or On failure (with an optional limit) when you run a
  container, or use `restart:` in a compose file. Container Desktop starts the container again when it stops
  (after 1 s, then 2 s, 4 s … up to a minute), and starts `always` / `unless-stopped` containers when the app
  launches or the container system comes up, so stacks return after a reboot. Containers you stop in the app stay
  stopped. Each restart appears in Activity; the Inspect tab shows the policy and the restart count.
  Apple's runtime has no restart policies, so this works only while Container Desktop is running (the window can
  be closed), a `container stop` typed in a terminal is treated as a crash, and "On failure" reacts to any
  unexpected stop because the runtime reports no exit codes. Switch it off under Settings › General.
- **Restart policies while the app is closed** (optional, off by default). Settings › General › "Keep enforcing
  when Container Desktop is closed" installs a small background helper that takes over the restarts, keeps going
  after you quit the app and starts at login. Containers you stop in the app still stay stopped, and the app and
  the helper never both restart a container. The helper waits for the container system and does not start it, so
  after a reboot nothing comes back until the container system is running. Its restarts are in the system log,
  not in Activity. Switching the setting off removes the helper; if you delete the app while it is on, see
  "Uninstalling" in the README. A `container stop` typed in a terminal is still treated as a crash.
- **Compose: wait for healthy dependencies.** `depends_on` with `condition: service_healthy` runs the dependency's
  `healthcheck` inside its container and starts the dependent service only once it passes, with a live "Waiting
  for db to be healthy (attempt 3)" step. `service_completed_successfully` waits for the dependency to finish. A
  dependency that never becomes healthy stops the run with the check's last output. Health is checked during the
  import, not afterwards.
- **Files tab** on every container: browse the filesystem of a running container with a path bar, back/up, inline
  expandable folders, a hidden-files toggle, and mounted volumes marked. Works with GNU, BusyBox and other minimal
  images; images without a shell show an explanation instead of an error. (#7)
  - Save files or folders to your Mac, upload from a file picker or by dragging from Finder, preview text files
    inline, open anything else in Quick Look, copy paths, create folders, rename and delete (with confirmation; the
    root, system directories and mount points are protected).
- **Save as Image…** creates a new image from a container (`container commit`). Requires Apple container 1.6 or
  later; on older versions the menu item says so.
- **Update checks.** Container Desktop says when a newer version of the app or of Apple's `container` runtime is
  available: a small "Update available" note in the status bar and menu bar, and a new **Settings → Updates** tab
  with release notes, a Download button and the matching Homebrew command. Also under **Container Desktop → Check
  for Updates…**. It checks github.com at most once a day, sends nothing about you or your containers, never
  installs anything by itself, and can be turned off.
- **Runtime compatibility notice** when the installed `container` is older than 1.5.0 or newer than the latest
  tested version.
- **Homebrew cask:** `brew install --cask AIFlow-Labs-Limited/tap/container-desktop`, upgrade with
  `brew upgrade --cask container-desktop`.
- **One-line installer** for Macs without Homebrew: downloads the latest release, verifies its checksum and copies
  the app to Applications (`scripts/install.sh`, with `--dry-run`).

- **Works with container 1.6.0, 1.6.1 and 1.7.1 as well as 1.5.0.** The app asks the installed CLI what its
  Kubernetes plugin supports instead of assuming a version, and picks up a CLI upgrade without a restart. What each
  release changes is in `docs/COMPATIBILITY.md`.
- Kubernetes on container 1.7: Kubernetes version, "Degraded (2 of 3 up)" state and worker nodes in the cluster
  list and inspector.
- New cluster: worker nodes (container 1.6+), separately sized worker groups and the shared image store (container
  1.7+), with Apple's security warning. Options the installed CLI lacks are disabled with a one-line reason.

### Changed
- **container 1.7.1 support is verified on a live engine (2026-11-12).** Save as Image, clusters with a worker
  group and the shared image store, the JSON cluster list, the degraded state, cluster nodes in the container
  list, CPU % from the runtime, image save and load, machines and builds all ran against a real 1.7.1 runtime, and
  the 1.7.1 test fixtures are now recorded from it. What was observed is in `docs/COMPATIBILITY.md`.
- Kubernetes commands and previews use `container cluster` on container 1.6.1 and later (`container k8s` before).
- "Load Image" is only offered where the CLI still has `load-image` (it was removed in container 1.7).
- CPU % uses the CLI's own `cpuUtilization` on container 1.7, so it shows from the first sample.
- The New Cluster sheet opens on a free name instead of a duplicate-name error.
- The "runtime not installed" screen is now a three-step guide: download Apple's installer or run
  `brew install container`, press **Check Again**, then **Start**.
- "Export…" is now "Export Filesystem…" and is also offered from the Files tab, including for stopped containers
  and images that cannot be browsed.

### Fixed
- Accented and Korean text in environment values, commands and paths reached the runtime in a different Unicode
  form than typed (`é` became `e` plus a combining accent). It now arrives byte for byte.
- Pressing Return in the Run sheet's Name or Command field now runs the container. (#1)
- The Run sheet's Image, Name, Command and other fields now have accessibility labels for VoiceOver. (#4)
- The sidebar said "Beta" and the Kubernetes page "Experimental"; both now say "Experimental". (#11)
- On container 1.7, cluster nodes stay visible under system containers and keep counting as users of their image,
  network and volumes; trying to stop or delete one explains that it belongs to a cluster.
- Engine: after `container system stop` the app showed a connection error with only Retry instead of the Stopped
  screen with Start. CLI 1.5.0 reports `{"status":"unregistered"}` with exit code 1, and list commands fail with an
  XPC connection error; both now mean "stopped". Start from the app works, and "Not installed" names the path that
  was searched. Engine probes run every 10 s in the background, so a stop shows in about 2 s and recovery in 6 s.
- Clean up: sizes now describe what each toggle removes (the stopped builder and the engine's whole-image estimate
  were counted before).
- Settings: resource steppers start from the engine's real defaults ("Default (1 GB)") instead of a hard-coded 4.
- Activity: CLI progress lines (written to stderr) are no longer painted red; only lines that read as errors are.
- Kubernetes: the cluster inspector warns when the `.test` DNS domain is not configured, since `kubectl --context`
  cannot resolve the node otherwise, and links to Settings → Network.
- Networks: "1 containers" grammar; overlapping-subnet warning verified against the default network.
- Terminal: a readable ANSI palette per appearance (directory colours were invisible on dark backgrounds).
- Zero byte values read "0 bytes" instead of "Zero KB".

- Images: saving "All platforms" of an image that was only downloaded for this Mac failed with the runtime's bare
  `content with digest sha256:…`. The error now says that some platforms were never downloaded and to choose a
  single platform.
- Save as Image: a container that no longer exists is reported as "not found" instead of a raw command failure
  (container 1.7.1 words that error differently).

### Known limitations
- container 1.6.0 and 1.6.1 were never installed: support for them is still read from Apple's source code. 1.5.0
  and 1.7.1 are verified live.
- Save as Image keeps the container's running process as the new image's entrypoint and command (that is what
  `container commit` does). Starting the image with a different command appends it to that entrypoint; set the
  entrypoint in the Run sheet to replace it.

## [0.1.0] - 2026-10-19

### Added
- **Containers.** Table with status, CPU, memory, ports and IP; compose-style grouping by project label; start,
  stop, restart, kill and delete, singly or in bulk, with confirmations that name what they touch. Detail tabs:
  Logs (follow, search, timestamps, boot log), Inspect (secrets masked), Terminal (embedded `container exec -it`
  via SwiftTerm, or Terminal.app), Stats (live CPU, memory, network, block I/O, PIDs charts), Mounts, Ports,
  Environment.
- **Run sheet** with image, name, command, ports (suggested from `EXPOSE`), volumes and binds, env and `.env`
  files, CPU and memory, platform, network, and a live preview of the exact `container run` command.
- **Images.** Pull with platform, tag, push, save and load tar files, prune with the reclaimable size shown first,
  platform badges, "used by", variants, config and layers.
- **Volumes and networks.** Create, inspect, prune, see which containers use them, reveal a volume's disk image in
  Finder, copy the `-v` / `--network` flag.
- **Builds.** Builder status and sizing; build sheet with context, Dockerfile, tags, platforms (arm64 and amd64
  through Rosetta), build args, target, secrets and SSH; streaming build log; local build history.
- **Container machines.** Create from images known to boot, open a terminal, resize, set the default.
- **Local Kubernetes** (experimental) through the `container` k8s plugin: create, delete, load images, copy the
  `kubectl --context` command. Shown only when the plugin is installed.
- **Registries.** Logins for Docker Hub, GHCR and custom registries; passwords go to the CLI over stdin only.
- **Settings.** DNS domains (`<name>.test`) through the standard admin prompt, default CPU and memory for
  containers, builder and machines, a validated `config.toml` editor, engine start and stop.
- **Shell.** Menu bar extra, status bar with engine state and resource usage, Clean up sheet, Activity window for
  long-running tasks, `⌘K` command palette, `⌘1`–`⌘8` sections, light and dark appearance, notifications.
- **Architecture.** `ContainerKit` (models mirroring the CLI's JSON, `ContainerBackend` protocol, CLI backend),
  fixture-backed `ContainerKitMock` recorded from CLI 1.5.0, `AppCore` stores, `DesignSystem`. Unknown CLI values
  decode to `.unknown` instead of failing.
- **Tooling.** `make check` (build, tests, `swift format lint --strict`) as the local gate with a pre-push hook;
  `make app`, `make dmg`, `make notarize`, `make release`, `make publish`. GitHub Actions workflows are manual
  only. App icon rendered from code.
