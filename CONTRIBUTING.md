# Contributing to Container Desktop

Thanks for helping. This is a native SwiftUI app for macOS 26 on Apple silicon, built as a Swift package
(no `.xcodeproj`).

## Setup

1. macOS 26 on Apple silicon, Xcode 27 (or a Swift 6.2+ toolchain): `xcode-select -p` should point at it.
2. Optional, for the real backend: Apple's `container` 1.5+ from
   [github.com/apple/container/releases](https://github.com/apple/container/releases), then `container system start`.
3. Clone and build:

```bash
git clone https://github.com/AIFlow-Labs-Limited/aiflowlabs-apple-containers-ui.git
cd aiflowlabs-apple-containers-ui
make check        # swift build + swift test + swift format lint (CI is manual-only: this IS the gate)
make hooks        # pre-push hook that runs make check automatically
make run-mock     # launch the app against recorded CLI fixtures — no runtime needed
```

You can open `Package.swift` in Xcode for SwiftUI previews; every view previews against `MockBackend`.

Read [`docs/PRD.md`](docs/PRD.md) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) before larger changes,
and [`CLAUDE.md`](CLAUDE.md) for the hard rules (the UI never shells out; everything goes through
`ContainerBackend`; destructive actions confirm; long actions stream output).

## Branches

`main` is always releasable. Work on a branch named `<area>/<short-description>`, for example
`containers/stop-timeout-menu`, `kit/volume-inspect`, `packaging/notarize`, `docs/readme-install`.

## Commits

`area: imperative summary`, lower case, no trailing period — e.g.

```
containers: add stop timeout menu
kit: decode network inspect subnets
packaging: sign DMG when a Developer ID is available
```

Areas: `kit`, `shell`, `containers`, `images`, `volumes`, `networks`, `builds`, `machines`, `kubernetes`,
`registries`, `settings`, `packaging`, `ci`, `docs`.

## Pull requests

- [ ] `make check` passes locally
- [ ] New CLI decoders come with a test against a fixture in `Sources/ContainerKitMock/Resources/`
- [ ] UI changes include before/after screenshots
- [ ] User-facing changes are listed under `## [Unreleased]` in `CHANGELOG.md`
- [ ] No secrets in code, logs, or fixtures

Keep PRs focused on one concern. Formatting: `make format` (4-space indent, 120 columns, config in `.swift-format`).

## Tests and the real runtime

Tests run against `MockBackend` and must never create, delete, or prune real `container` resources.
To re-record fixtures from a newer CLI, use `scripts/record-fixtures.sh` and review the diff.

## Releasing (maintainers)

See [`docs/release/RELEASING.md`](docs/release/RELEASING.md).
