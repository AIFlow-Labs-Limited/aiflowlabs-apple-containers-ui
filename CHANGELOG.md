# Changelog

All notable changes to Container Desktop are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Swift package scaffold: `ContainerKit` (models + `ContainerBackend` contract + CLI backend), fixture-backed
  `ContainerKitMock`, `AppCore`, `DesignSystem`, and the `ContainerDesktop` app target.
- Packaging: `make app` (signed `.app` bundle with icon and SwiftPM resources), `make dmg`, `make notarize`,
  `make icon`, `make lint`, `make check`, `make release`.
- App icon rendered from code (`scripts/make-icon.swift`).
- GitHub Actions CI (build, test, lint, bundle) and tag-driven release workflow that publishes the DMG.
- Homebrew cask draft (`packaging/homebrew/container-desktop.rb`; the tap is not published yet).

### Fixed
- Builds: the chosen Dockerfile and `--secret src=` paths are passed as absolute paths, so builds work when the
  app is opened from Finder; `Dockerfile.dockerignore` is no longer offered as a Dockerfile; Reset builder is
  disabled while a build runs.
- Volume, network and image prune confirmations count every unused resource, including ones hidden by the search,
  and the result toast reports what was actually removed.
- Machines: removed the User/UID/GID fields (`container machine create` 1.5 has no `--user`); Docker Hub's
  `alpine` is blocked with a one-click switch to the verified image; duplicate names are caught before creating;
  the terminal session survives switching to Overview or Logs.
- Push warns before re-pointing an existing local tag; pulling both architectures runs the pulls one after the
  other; "Sign in…" opens the login sheet for that registry.
- Release tooling: `release.sh` checks branch, sync, remote tags and runs `make check`; `notarize.sh` rejects
  unsigned artifacts; `bundle.sh` signs without `--deep`; README/RELEASING give current Gatekeeper steps.
