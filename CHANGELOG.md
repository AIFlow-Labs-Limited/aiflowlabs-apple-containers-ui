# Changelog

All notable changes to Container Desktop are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
