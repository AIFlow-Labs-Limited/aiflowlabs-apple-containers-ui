# Container Desktop — agent instructions

Native macOS app (SwiftUI, macOS 26+, Apple silicon) that manages Apple's `container` runtime the
way Docker Desktop manages Docker. Read `docs/PRD.md` (what) and `docs/ARCHITECTURE.md` (how) first.

## Build / test / run

```bash
swift build                       # package (all targets)
swift test                        # ContainerKitTests + AppCoreTests
make app                          # .app bundle at build/Container Desktop.app
make run                          # build + launch against the real CLI
make run-mock                     # build + launch with CONTAINER_DESKTOP_BACKEND=mock (no runtime needed)
swift run ContainerDesktop        # quick launch without the bundle (no icon/plist)
```
The real runtime: `container system status` must say `running` (`container system start` if not).
Never run `container` commands that delete/prune real user resources from tests; use `MockBackend`.

## Hard rules

1. **UI code never shells out.** Every feature goes through `ContainerBackend` (Sources/ContainerKit/Backend).
   If something is missing from the protocol, add it to the protocol + `MockBackend` + `CLIBackend`.
2. **Swift 6 strict concurrency, no `@unchecked Sendable`, no `DispatchQueue`.** Stores are `@MainActor @Observable`.
   Backends are actors or `Sendable` structs.
3. **Models mirror CLI JSON field names** (`configuration.id`, `status.state`, …). Add derived helpers as
   computed properties, never rename decoded fields. Unknown enum strings decode to `.unknown`, never throw.
4. **Fixtures are truth.** `Sources/ContainerKitMock/Resources/cli-1.5.0/*.json` were recorded from CLI 1.5.0.
   New decoders get a test against a fixture. Re-record with `scripts/record-fixtures.sh`.
5. **Docker Desktop parity in layout and vocabulary** (sidebar: Containers · Images · Volumes · Networks ·
   Builds · Machines · Kubernetes · Registries; container tabs: Logs · Inspect · Terminal · Stats · Mounts · Ports),
   but native macOS look (SF Symbols, system materials, `Table`, `NavigationSplitView`, `Settings` scene).
6. **Every destructive action confirms** (delete, prune, force-stop) and names what it removes.
7. **Every long-running action streams output** (pull/push/build/create) into a task sheet or the Activity
   panel; never block the UI with a spinner alone.
8. **Errors surface as `BackendError`** rendered by `ErrorBanner`/alerts with the cleaned CLI message and the
   exact command (copyable).
9. **No secrets in code, logs, or fixtures.** Registry passwords go to the CLI via stdin only.
10. **One concern per file; files ≤ ~400 lines.** Feature folders: `Sources/ContainerDesktop/Features/<Area>/`.

## Style

- 4-space indent, 120 cols, `swift-format` defaults (`make format`).
- SwiftUI views: `struct XView: View` + `#Preview` using `MockBackend` via `.environment(\.backend, …)`.
- Naming: `ContainersStore`, `ContainerDetailView`, `RunContainerSheet`, `PullImageSheet`.
- Comments explain *why*; docs comments on every public symbol in ContainerKit/AppCore.
- Commit messages: `area: imperative summary` (e.g. `containers: add stop timeout menu`).

## Ownership map (parallel workstreams)

| Path | Owner stream |
|---|---|
| `Sources/ContainerKit/**` | kit (backend + models) |
| `Sources/ContainerKitMock/**` | kit |
| `Sources/AppCore/**`, `Sources/DesignSystem/**`, `Sources/ContainerDesktop/App/**` | shell |
| `Sources/ContainerDesktop/Features/Containers/**` | features-containers |
| `Sources/ContainerDesktop/Features/{Images,Volumes,Networks,Builds}/**` | features-resources |
| `Sources/ContainerDesktop/Features/{Machines,Kubernetes,Registries}/**` | features-platform |
| `Makefile`, `scripts/**`, `.github/**`, `Resources/**`, `README.md`, `docs/release/**` | packaging |

Touch another stream's files only to fix a compile break, and say so in the commit message.
