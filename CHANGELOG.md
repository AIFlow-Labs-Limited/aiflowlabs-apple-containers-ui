# Changelog

All notable changes to Container Desktop are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Import Compose File** (File › Import Compose File…, ⇧⌘O; also in the Containers toolbar, the ⌘K palette, or drop
  a `compose.yaml` / `docker-compose.yml` on the window). Container Desktop reads the file, shows the services,
  volumes and networks it found, and lists the exact `container` commands it will run before anything starts.
  - Supports the common Compose keys: images and builds, ports, volumes and bind mounts, environment and env files,
    `depends_on` start order, resource limits, profiles, and `${VARIABLE}` values from the `.env` file next to the
    compose file (each can be overridden in the preview).
  - Everything Apple's runtime cannot do (restart policies, health checks, secrets, host networking, …) is listed
    per service in the preview instead of being silently dropped. See `docs/COMPOSE.md`.
  - The preview says which hostname services can use to reach each other on your setup, and warns when no DNS
    domain is configured.
  - Running a project shows progress per step. If a step fails, the run stops, says what was already created, and
    offers to remove it. Existing containers with the same name are never replaced without asking; existing
    volumes and networks are reused.
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

### Changed
- The "runtime not installed" screen is now a three-step guide: download Apple's installer or run
  `brew install container`, press **Check Again**, then **Start**.
- "Export…" is now "Export Filesystem…" and is also offered from the Files tab, including for stopped containers
  and images that cannot be browsed.

### Fixed
- Pressing Return in the Run sheet's Name or Command field now runs the container. (#1)
- The Run sheet's Image, Name, Command and other fields now have accessibility labels for VoiceOver. (#4)
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
