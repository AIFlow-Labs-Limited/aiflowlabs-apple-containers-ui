# Launch posts (drafts, review before posting)

Repo: https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui
Assets: `docs/launch/hero.png`, `docs/launch/social-preview.png` (set it under Settings → Social preview),
`docs/launch/demo.gif`, `docs/launch/demo.mp4`, `docs/screenshots/*`.

Checklist before posting: a release with a DMG exists, the README install steps work on a clean Mac, every claim
below still matches the app, and someone is around to answer comments for the first few hours.

---

## Hacker News

**Title** (≤ 80 chars):

> Show HN: Container Desktop – a native Mac GUI for Apple's container runtime

**First comment:**

Hi HN. Apple's `container` (github.com/apple/container) runs each Linux container in its own lightweight VM on
Apple silicon. It uses OCI images, has no background daemon and no license fee. It is a command-line tool only, so
switching from Docker Desktop means losing the window most of us keep open all day: what is running, start and
stop, logs, a shell, images, disk usage.

Container Desktop is that window, written in SwiftUI for macOS 26. It follows Docker Desktop's layout and
vocabulary (Containers, Images, Volumes, Networks, Builds), so there is little to learn: a containers table with
compose-style grouping by label, detail tabs for logs, inspect, an embedded terminal (`container exec -it` in
SwiftTerm), stats charts, mounts, ports and environment, plus a Run sheet that previews the exact `container run`
command it will execute. It also covers what is specific to Apple's runtime: container machines (persistent Linux
VMs with your home folder mapped), DNS domains like `<name>.test`, Rosetta for `linux/amd64` images, and local
Kubernetes through the experimental k8s plugin.

Under the hood the UI never shells out directly. Everything goes through one `ContainerBackend` protocol. Today
that is a CLI backend that runs `container … --format json`. Its models mirror the CLI's JSON, and the tests run
against fixtures recorded from CLI 1.5. The plan is to add an XPC backend that talks to the container services
directly, without touching the views.

It is v0.1 and MIT licensed. The DMG is ad-hoc signed, not notarized yet, so the first launch needs "Open Anyway" in
Privacy & Security (the README has the steps). Next up: compose-file import, a file browser inside containers and
a notarized build. I would like to hear what is missing for your daily workflow, and about any CLI output that
breaks the app: https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui

---

## X / Twitter (thread of 5)

**1/**
Apple's `container` runs Linux containers on your Mac, each in its own lightweight VM. No daemon, no license fee.

What it doesn't have is a GUI. So we built one.

Container Desktop: the Docker Desktop experience for Apple's runtime. Native SwiftUI, MIT.
[demo.gif]

**2/**
Same layout and words you already know: Containers, Images, Volumes, Networks, Builds.

Live CPU / memory / network per container, logs with search and follow, inspect, ports, env, and an embedded
terminal into any container.
[containers-dark.png]

**3/**
The Run sheet previews the exact `container run` command as you fill it in. Ports suggested from EXPOSE, volumes,
.env files, CPU and memory, platform. Copy the command or press Run.

Long jobs (pulls, builds) stream into an Activity window instead of a spinner.
[run-container-dark.png]

**4/**
And the parts only Apple's runtime has:
• container machines: Linux dev VMs with your home folder mapped
• `<name>.test` DNS domains
• Rosetta for linux/amd64 images and builds
• local Kubernetes via the k8s plugin (experimental)
[machines-dark.png]

**5/**
v0.1 is out. macOS 26, Apple silicon, `container` 1.5+.

Download, source and roadmap (compose import, XPC backend, notarized builds):
https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui

Issues and PRs welcome.

---

## LinkedIn

Apple released `container`, an open-source runtime that runs each Linux container in its own lightweight virtual
machine on Apple silicon. It has no daemon and no license fee, and it ships as a command-line tool only.

At AIFLOW LABS we build robotics and physical-AI software and live in containers every day, so we built the missing
piece: **Container Desktop**, a native macOS app that gives Apple's runtime the Docker Desktop experience.

• Containers, Images, Volumes, Networks and Builds in the layout Docker Desktop users already know
• Logs, live stats, inspect and an embedded terminal for every container
• A Run sheet that shows the exact command before it runs
• Apple-only features: container machines, local DNS domains, Rosetta for amd64 images, local Kubernetes

It is open source (MIT) and v0.1 is available now for macOS 26 on Apple silicon. Feedback and contributions are
welcome:
https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui

#macOS #containers #opensource #SwiftUI #developertools

---

## Reddit, r/macapps

**Title:** Container Desktop: a free, open-source native GUI for Apple's `container` runtime (Docker Desktop-style)

**Body:**

Apple's `container` CLI runs Linux containers on Apple silicon, each in its own lightweight VM. There was no GUI, so
I built one in SwiftUI.

What it does:
- Containers table (status, CPU, memory, ports, IP), with start, stop, restart, delete and compose-style grouping
- Per-container logs, inspect, live stats charts, mounts, ports, environment, and an embedded terminal
- Images (pull, tag, push, save and load, prune), volumes, networks, builds with live logs
- Container machines (Linux dev VMs with your home folder), DNS domains, local Kubernetes (experimental)
- Menu bar extra, ⌘K command palette, light and dark

Requirements: macOS 26, Apple silicon, `container` 1.5+. MIT licensed. The DMG is not notarized yet, so the first
launch needs System Settings → Privacy & Security → Open Anyway (steps in the README).

https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui

Feedback very welcome, especially on what feels un-Mac-like.

---

## Reddit, r/docker

**Title:** For Mac users trying Apple's `container` runtime: I made a Docker Desktop-style GUI for it (open source)

**Body:**

If you have tried Apple's `container` (github.com/apple/container) as a Docker Desktop alternative on Apple
silicon, you have probably missed the dashboard. Container Desktop is an open-source macOS app that brings it back,
using the same concepts: Containers, Images, Volumes, Networks, Builds, a Run dialog, logs, exec into a container,
prune.

A few differences worth knowing about Apple's runtime, which the app surfaces instead of hiding:
- every container is its own VM (per-container CPU and memory limits, its own IP)
- `linux/amd64` images run and build through Rosetta
- containers on custom networks can't resolve each other by name yet; the app warns about this and points to DNS
  domains
- "container machines" are persistent Linux VMs with your home folder mapped, roughly a built-in dev box

It is not a Docker replacement for every case: there is no compose import yet (planned for v0.2) and no GPU support
(the runtime has none). The Run sheet and build sheet show the equivalent `container` command, which helps when
translating `docker run` habits.

MIT, macOS 26 + Apple silicon: https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui
