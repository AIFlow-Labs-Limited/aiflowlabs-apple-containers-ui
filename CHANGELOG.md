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
- Homebrew cask draft (`packaging/homebrew/container-desktop.rb`).
