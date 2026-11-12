<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="Container Desktop icon">
</p>

<h1 align="center">Container Desktop</h1>

<p align="center">
  <strong>The Docker Desktop experience for Apple's native <code>container</code> runtime.</strong><br>
  A native SwiftUI app to run, inspect and manage Linux containers on your Mac. No daemon, no license fees.
</p>

<p align="center">
  <a href="https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui/releases"><img src="https://img.shields.io/github/v/release/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui?include_prereleases&sort=semver" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2026%20%C2%B7%20Apple%20silicon-lightgrey.svg" alt="Platform: macOS 26 · Apple silicon">
  <a href="https://aiflowlabs.io"><img src="https://img.shields.io/badge/built%20by-AIFLOW%20LABS-6f42c1.svg" alt="Built by AIFLOW LABS"></a>
</p>

<p align="center">
  <img src="docs/launch/hero.png" alt="Container Desktop: the containers list with a compose-style stack and live CPU, memory and network charts for the selected container">
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#what-you-get">Features</a> ·
  <a href="#new-in-v02">New in v0.2</a> ·
  <a href="#demo">Demo</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#roadmap">Roadmap</a>
</p>

## Why this exists

Apple shipped [`container`](https://github.com/apple/container): every Linux container runs in its own lightweight
virtual machine on the open-source [Containerization](https://github.com/apple/containerization) framework. It
speaks OCI images, needs no background daemon and costs nothing. It ships as a command-line tool only.

If you come from Docker Desktop, you lose the window you live in: what is running, one-click start and stop, logs,
a shell into a container, images, disk usage.

Container Desktop is that window. It keeps Docker Desktop's layout and vocabulary, so there is nothing to
re-learn, behaves like a Mac app (SF Symbols, native tables, Settings, a menu bar extra, light and dark), and exposes
what only Apple's runtime has: container machines, DNS domains, Rosetta for `amd64` images and local Kubernetes.

> **Status: v0.2, pre-1.0.** It works with `container` 1.5.0 through 1.7.1 (see
> [compatibility](docs/COMPATIBILITY.md)). Expect rough edges until 1.0, and builds that are not notarized yet
> (see [Install](#install)).

## What you get

<table>
  <tr>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/container-logs-dark.png">
        <img src="docs/screenshots/container-logs-light.png" alt="Containers list with the db container's live logs">
      </picture>
      <h3>Containers</h3>
      Status, CPU, memory, ports and IP in one table, with compose-style stacks grouped by project label.
      Start, stop, restart, kill and delete, one at a time or in bulk. Detail tabs for <b>Logs</b> (follow, search,
      timestamps, boot log), <b>Inspect</b>, <b>Terminal</b>, <b>Stats</b>, <b>Mounts</b>, <b>Ports</b> and
      <b>Environment</b>.
    </td>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/container-terminal-dark.png">
        <img src="docs/screenshots/container-terminal-light.png" alt="An embedded shell inside the db container">
      </picture>
      <h3>A real terminal</h3>
      An embedded terminal runs <code>container exec -it</code> with the shell you pick, or opens the same
      command in Terminal.app.
    </td>
  </tr>
  <tr>
    <td valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/run-container-dark.png">
        <img src="docs/screenshots/run-container-light.png" alt="The Run a New Container sheet with a live command preview">
      </picture>
      <h3>Run sheet</h3>
      Image, name, command, ports (suggested from the image's <code>EXPOSE</code>), volumes and binds, env and
      <code>.env</code> files, CPU and memory, platform, network and more. The exact <code>container run</code>
      command is previewed as you type and can be copied.
    </td>
    <td valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/image-detail-dark.png">
        <img src="docs/screenshots/image-detail-light.png" alt="Images list with the postgres image's details">
      </picture>
      <h3>Images</h3>
      Pull (with platform), tag, push, save and load tar files, and prune with the reclaimable size shown first.
      Platform badges, which containers use an image, variants, config and layers.
    </td>
  </tr>
  <tr>
    <td valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/volumes-dark.png">
        <img src="docs/screenshots/volumes-light.png" alt="Volumes list with the pgdata volume selected">
      </picture>
      <h3>Volumes and networks</h3>
      Create, inspect and prune volumes and networks, see which containers use them, reveal a volume's disk image
      in Finder, and copy the <code>-v</code> or <code>--network</code> flag.
    </td>
    <td valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/build-sheet-dark.png">
        <img src="docs/screenshots/build-sheet-light.png" alt="The Build image sheet with arm64 and amd64 platforms">
      </picture>
      <h3>Builds</h3>
      Builder status and sizing, and a build sheet for context, Dockerfile, tags, platforms, build args, target,
      secrets and SSH. Builds stream a live log and are kept in a local history.
    </td>
  </tr>
  <tr>
    <td valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/machines-dark.png">
        <img src="docs/screenshots/machines-light.png" alt="Container machines list with a running dev machine">
      </picture>
      <h3>Container machines <sub>Apple only</sub></h3>
      Persistent Linux dev machines with your home folder mapped at the same path. Create from images known to
      boot, open a terminal, resize, set the default.
    </td>
    <td valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/kubernetes-dark.png">
        <img src="docs/screenshots/kubernetes-light.png" alt="A local Kubernetes cluster with its node and kubectl commands">
      </picture>
      <h3>Local Kubernetes <sub>experimental</sub></h3>
      Clusters through the <code>container</code> k8s plugin, where each node is a container. Create, delete,
      load local images into a cluster, copy the <code>kubectl --context</code>. Shown only when the plugin is installed.
    </td>
  </tr>
  <tr>
    <td valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/settings-network-dark.png">
        <img src="docs/screenshots/settings-network-light.png" alt="Network settings with DNS domains and host.container.internal">
      </picture>
      <h3>DNS domains and settings <sub>Apple only</sub></h3>
      Make containers reachable as <code>&lt;name&gt;.test</code> through the standard admin prompt. Default CPU and
      memory for containers, the builder and machines, a validated <code>config.toml</code> editor, engine start
      and stop.
    </td>
    <td valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/command-palette-dark.png">
        <img src="docs/screenshots/command-palette-light.png" alt="The command palette over the containers list">
      </picture>
      <h3>Keyboard first</h3>
      <kbd>⌘K</kbd> jumps to any container, image or volume and runs actions. <kbd>⌘N</kbd> opens the Run sheet,
      <kbd>⌘1</kbd>–<kbd>⌘8</kbd> switch sections. Long-running work (pulls, builds, machine and cluster creation)
      streams into the Activity window.
    </td>
  </tr>
</table>

Also included: a menu bar extra (running containers, engine start and stop), a status bar with engine state,
running count, CPU, RAM and disk usage, a **Clean up** sheet that names what it will remove, registry logins for
Docker Hub, GHCR and others (passwords go to the CLI over stdin only), and `linux/amd64` runs and builds through
Rosetta next to native `arm64`. More screens: [`docs/screenshots/`](docs/screenshots/).

## New in v0.2

<table>
  <tr>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/compose-import-dark.png">
        <img src="docs/screenshots/compose-import-light.png" alt="The Import Compose File sheet showing services, hostnames, variables and differences from Docker Compose">
      </picture>
    </td>
    <td width="50%" valign="top">
      <picture>
        <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/container-files-dark.png">
        <img src="docs/screenshots/container-files-light.png" alt="The Files tab browsing a running container's /app folder">
      </picture>
    </td>
  </tr>
</table>

- **Import Compose File.** Open a `compose.yaml` or `docker-compose.yml` (File menu, ⇧⌘O, the Containers toolbar,
  ⌘K, or drop it on the window). The app shows the services, volumes and networks it found, lists the exact
  `container` commands it will run, and names everything Apple's runtime cannot do instead of dropping it
  silently. The stack then appears as a project group with Start All, Stop All and Delete All.
  Supported keys and limits: [docs/COMPOSE.md](docs/COMPOSE.md).
- **Files tab** on every container: browse a running container's filesystem, save files and folders to your Mac,
  upload by file picker or drag from Finder, preview text, Quick Look the rest, rename, delete (with confirmation)
  and export the whole filesystem as a tar.
- **Save as Image…** turns a container into an image (`container commit`, needs `container` 1.6 or later).
- **Updates.** The app tells you when a newer Container Desktop or a newer Apple runtime exists, in the status bar
  and in **Settings → Updates**. It checks github.com once a day, sends nothing about you, installs nothing by
  itself, and can be turned off.
- **Runtime 1.6 and 1.7.** Kubernetes follows Apple's rename from `container k8s` to `container cluster`, with
  worker nodes and the shared image store on runtimes that have them. The app asks the installed runtime what it
  supports, so 1.5 keeps working.
- **Easier install:** Homebrew cask and a one-line installer that verifies the download checksum.

## Demo

<p align="center">
  <img src="docs/launch/demo.gif" width="900" alt="Pull redis:7, watch it stream in Activity, run it from the Run sheet, then open its logs and a terminal">
</p>

Pull an image, watch it stream into Activity, run a container from the Run sheet, then read its logs and open a
shell. A higher-quality [MP4](docs/launch/demo.mp4) is in the repo.

## Install

**Requirements:** macOS 26 (Tahoe) or later on Apple silicon, and Apple's
[`container`](https://github.com/apple/container) runtime 1.5.0 or later (tested up to 1.7.1). Container Desktop
is a dashboard for that runtime; it does not include it.

### 1. Homebrew (recommended)

```bash
brew install container                                            # Apple's runtime, if you do not have it yet
brew install --cask AIFlow-Labs-Limited/tap/container-desktop
```

### 2. One-line installer

No Homebrew? This downloads the latest release, checks it against its published SHA-256 checksum and copies the
app to `/Applications`. It does not use `sudo`, and it asks before replacing an existing copy.

```bash
curl -fsSL https://raw.githubusercontent.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui/main/scripts/install.sh | bash
```

To see what it would do without changing anything, add `-s -- --dry-run` after `bash`. Other options:
`--yes` (replace without asking), `--version X.Y.Z`, `--dir ~/Applications`. You can
[read the script](scripts/install.sh) first.

### 3. Download the DMG

1. Download `Container-Desktop-<version>-arm64.dmg` from
   [Releases](https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui/releases/latest), open it and
   drag *Container Desktop* to *Applications*.
2. Optional: each release has a `.sha256` file. With both files in the same folder,
   `shasum -a 256 -c Container-Desktop-<version>-arm64.dmg.sha256` should print `OK`.

### First launch

Builds are ad-hoc signed and not notarized yet, so macOS blocks the first launch of a copy installed with
Homebrew or from the DMG (right-click → Open no longer bypasses this, and a quarantined ad-hoc app can be
reported as "damaged"). Either open the app once, then go to **System Settings → Privacy & Security** and click
**Open Anyway**, or remove the quarantine flag:

```bash
xattr -dr com.apple.quarantine "/Applications/Container Desktop.app"
```

A copy installed with the one-line installer normally opens without this step, because `curl` does not mark
downloads as quarantined.

### The runtime

If Apple's runtime is missing, Container Desktop says so on launch and shows the way: install it with
`brew install container` or with the signed installer from
[apple/container releases](https://github.com/apple/container/releases/latest), press **Check Again**, then press
**Start container system** (the app runs `container system start` for you).

### Updating

Container Desktop checks github.com once a day for a newer release of itself and of the runtime and shows a small
"Update available" note in the status bar; details are in **Settings → Updates** (or **Container Desktop → Check
for Updates…**). The check sends nothing about you or your containers, and you can turn it off there. The app
never downloads or installs anything by itself.

| Installed with | Update Container Desktop | Update the runtime |
|---|---|---|
| Homebrew | `brew upgrade --cask container-desktop` | `brew upgrade container` |
| One-line installer | run the installer again (add `-s -- --yes` after `bash` to skip the question) | installer from [apple/container releases](https://github.com/apple/container/releases/latest) |
| DMG | download the new DMG and replace the app in *Applications* | installer from [apple/container releases](https://github.com/apple/container/releases/latest) |

Quit Container Desktop before replacing it; your containers keep running. Upgrading the **runtime** is different:
running containers stop, so stop what matters first and start the container system again afterwards. Homebrew's
`container` formula can be a few days behind Apple's release.

### Uninstalling

| Installed with | Remove the app | Also remove its settings and build history |
|---|---|---|
| Homebrew | `brew uninstall --cask container-desktop` | `brew uninstall --zap --cask container-desktop` |
| Installer or DMG | quit the app, then move *Container Desktop* from *Applications* to the Trash | see below |

Container Desktop keeps two things outside the app, both small:

```bash
rm -rf ~/Library/Application\ Support/Container\ Desktop                 # build history
rm -f ~/Library/Preferences/io.aiflowlabs.containerdesktop.plist         # settings
```

Removing Container Desktop does not touch your containers, images or volumes: they belong to Apple's runtime.
To remove the runtime as well, follow [apple/container](https://github.com/apple/container)'s instructions (or
`brew uninstall container` if you installed it with Homebrew).

### Build from source

Xcode 27 (or a Swift 6.2+ toolchain) on macOS 26:

```bash
git clone https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui.git
cd aiflowlabs-apple-containers-ui
make run-mock   # launch against recorded CLI fixtures, no runtime needed
make run        # launch against your real `container` installation
make dmg        # build/Container-Desktop-<version>-arm64.dmg
```

## How it works

```
SwiftUI views ─▶ @Observable stores (AppCore) ─▶ ContainerBackend protocol (ContainerKit)
                                                   ├─ CLIBackend   runs `container … --format json` (today)
                                                   ├─ MockBackend  recorded CLI fixtures (previews, tests)
                                                   └─ XPC backend  talks to the container services directly (planned)
```

- **The UI never shells out.** Every action goes through `ContainerBackend`, so the CLI backend can be swapped
  for an XPC backend without touching a view.
- **Models mirror the CLI's JSON**, and unknown values decode to `.unknown` instead of failing, so a new CLI
  release does not break the app.
- **Tests run against fixtures recorded from the real CLI** (`swift test`, no runtime needed). CI is manual-only;
  the gate is `make check` (build, tests, `swift format lint --strict`), run locally and by a pre-push hook.

Details in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md); scope in [`docs/PRD.md`](docs/PRD.md).

## Roadmap

- **v0.1:** the dashboard. Containers, Images, Volumes, Networks, Builds, Machines, Kubernetes, Registries,
  engine control, settings, menu bar extra; ad-hoc signed DMG.
- **v0.2 (this release):** compose-file import, a file browser inside containers, Save as Image, update checks,
  Homebrew cask and one-line installer, support for `container` 1.6 and 1.7.
- **Next:** a signed and notarized DMG, compose health checks and restart policies where the runtime allows,
  XPC backend (no CLI round-trips), menu-bar-only mode.
- **Later:** remote hosts.

How this compares with Docker Desktop today, including what is still missing: [docs/COMPARISON.md](docs/COMPARISON.md).

Ideas and votes are welcome in [Issues](https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui/issues).

## Contributing

Contributions are welcome. Start with [`CONTRIBUTING.md`](CONTRIBUTING.md): setup, `make check`, branch and
commit conventions. `make run-mock` gives you the whole app on recorded data, and every view has a SwiftUI preview.
Please report security issues privately as described in [`SECURITY.md`](SECURITY.md).

## License

[MIT](LICENSE) © 2026 AIFLOW LABS LIMITED.

Container Desktop is an independent project. It is not affiliated with or endorsed by Apple Inc. or Docker, Inc.;
"Docker Desktop" is used only to describe familiar concepts.

## Credits

- [apple/container](https://github.com/apple/container) and
  [apple/containerization](https://github.com/apple/containerization), the runtime this app drives.
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza, the embedded terminal.

## About AIFLOW LABS

[AIFLOW LABS](https://aiflowlabs.io) builds robotics and physical-AI software. We build our own tools in the open,
and Container Desktop is the one we use every day on our Macs.
