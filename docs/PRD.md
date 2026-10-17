# Container Desktop — Product Requirements

**Status:** v1 scope locked 2026-10-18 · **Owner:** AIFLOW LABS LIMITED · **License:** MIT

## 1. Why

Apple ships `container` (macOS 26, Apple silicon): per-container lightweight VMs, OCI images, no Docker daemon,
no licensing. It has **no GUI**. Docker Desktop users who switch lose the dashboard they rely on: a glance at
what is running, one-click start/stop, logs, a terminal into a container, image management, disk usage.
Existing community attempts are either read-only menu-bar monitors or two-week-old prototypes.

**Container Desktop** is the missing dashboard: a native macOS app that feels like Docker Desktop (so nobody
re-learns anything) while exposing what is unique to Apple's runtime (container machines, per-VM resources,
DNS domains, Rosetta, local Kubernetes).

## 2. Users

| Persona | Needs |
|---|---|
| Developer leaving Docker Desktop | Same mental model: Containers / Images / Volumes, Run dialog, Logs, Exec. Zero CLI. |
| macOS-native developer | A Linux dev box (container machine) with their home folder, one click. |
| Platform/robotics engineer (AIFLOW) | Multi-arch builds for Linux servers, compose-style stacks, resource visibility. |
| Curious newcomer | Install `container`, start the system, run first image — guided, no terminal. |

## 3. Scope — v1.0 (ship)

### 3.1 Shell
- Sidebar (Docker Desktop order): **Containers, Images, Volumes, Networks, Builds, Machines, Kubernetes, Registries**; Settings in the toolbar/`⌘,`.
- Global search / command palette (`⌘K`): jump to any container/image/volume, run actions.
- Bottom status bar: engine state (running/stopped/not installed), CLI version, running count, CPU/RAM of all containers, disk used / reclaimable, "Clean up" button.
- Engine states: **Not installed** (download link, detects install), **Stopped** (Start button; first-run kernel install prompt), **Running**.
- Menu bar extra: running count, start/stop containers, open app, start/stop engine, quit.
- Notifications (in-app toasts + optional system notifications) for finished pulls/builds and crashes.
- Activity panel: list of in-flight and recent long-running tasks with live output.
- Settings: General (launch at login, start engine on launch, show stopped, menu bar, polling interval, theme), Resources (default CPUs/memory for containers, builder, machines → config.toml), Engine (raw config.toml editor with validation, restart engine), Network (DNS domain setup incl. `sudo container system dns create` via admin prompt; host.container.internal helper; VPN fake-IP warning), Updates (check GitHub releases), About (versions, backend, diagnostics export).

### 3.2 Containers
- Table: status dot, Name, Image, Status (Running 2h / Exited), CPU %, Memory, Ports (clickable → browser), IP, Started, actions (▶/■, ⋯ menu: restart, kill, delete, copy IP, copy `container run` equivalent, open terminal, export).
- Filters: running/all, search, project label grouping (compose-style stacks collapse into groups), hide system containers (builder, k8s nodes) toggle.
- Bulk select → start/stop/delete.
- Detail (right pane, tabs): **Logs** (follow, search, wrap, timestamps, boot log toggle, save), **Inspect** (key facts + raw JSON tree, copy), **Terminal** (embedded, `container exec -it`, shell picker), **Stats** (CPU/mem/net/block charts over the session), **Mounts** (bind/volume/tmpfs, reveal in Finder), **Ports** (open, copy), **Environment**.
- **Run new container** sheet (Docker Desktop's "Optional settings" plus Apple extras): image picker (local or pull), name, command, ports (+auto-suggest from image EXPOSE), volumes/binds (folder picker), env (+ .env file), CPU/memory sliders, platform (arm64/amd64 Rosetta), network/aliases, init, read-only, SSH forward, labels. Preview of the generated command, "Copy command".

### 3.3 Images
- Table: Name, Tag, Platforms (arm64/amd64 badges), In use, Created, Size; actions: Run, Pull latest, Push, Tag, Save…, Delete.
- Pull sheet (reference + platform), Load from tar, Prune (dangling / all) with reclaimable size.
- Detail: variants, config (cmd/entrypoint/env/ports/labels), layers (history), digest, "Run" shortcut.

### 3.4 Volumes & Networks
- Volumes: Name, In use (by which containers), Created, Max size, backing path; create (size/journal), delete, prune, reveal.
- Networks: Name, Subnet, Gateway, Attached containers; create (subnet v4/v6), delete, prune. Explain `default` vs isolated (DNS caveat).

### 3.5 Builds
- Builder status card (running, CPU/mem, image), start/stop/reset with sizing.
- Build sheet: context folder, Dockerfile, tag, platforms, build-args, target, no-cache, secrets, SSH; live log; result → Images.
- Build history (local, persisted): tag, duration, status, log.

### 3.6 Machines (Apple-only)
- List: name, state, CPUs, memory, disk, default badge, image; create sheet (curated images that are known to boot + custom), open terminal, stop, delete, set default, resize.
- Explain what a machine is (home folder mapped, init system, security note).

### 3.7 Kubernetes (experimental badge)
- Clusters: name, nodes, state; create (name, cpus, memory, node image, CNI file), delete, load image into cluster, copy `kubectl --context`.
- Hidden when the CLI has no `k8s` plugin.

### 3.8 Registries
- Logins list; add login (server, username, password → stdin), logout. Hints for Docker Hub PAT / GHCR.

### 3.9 Quality bar
- Launch < 1 s to first list; list refresh ≤ 2 s cadence while visible (pause when hidden); stats 2 s.
- Works with the engine stopped (shows state, never spins forever).
- All actions keyboard reachable; VoiceOver labels on table rows and buttons.
- Light/dark, Reduce Motion respected. Window state restored.
- No crash on CLI output we haven't seen (unknown enum → `.unknown`, extra JSON keys ignored).
- Unit tests for every decoder and store; UI smoke test launching against `MockBackend`.

## 4. Out of scope (v1)
Compose-file import (v1.1 — see `compose2ac` in the trainops skill), image vulnerability scanning,
extensions marketplace, remote hosts, GPU anything (runtime has none), Docker Hub browsing, file browser
inside containers (v1.1 via `container cp`/`exec ls`).

## 5. Success metrics
- GitHub: 500 stars in 60 days; featured in awesome-apple-container lists; HN launch front page.
- Product: 0 "how do I" issues that the UI should have answered; < 1% crash-free sessions lost.

## 6. Naming & distribution
Working name **Container Desktop** (bundle `io.aiflowlabs.containerdesktop`; rename = one Makefile variable).
Distributed as a notarized DMG via GitHub Releases + Homebrew cask (`brew install --cask container-desktop`).
