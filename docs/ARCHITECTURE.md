# Architecture

Swift Package (no `.xcodeproj` checked in; open `Package.swift` in Xcode). macOS 26+, Swift 6 strict concurrency.

```
┌───────────────────────────── ContainerDesktop (executable) ─────────────────────────────┐
│  App/            window, sidebar, status bar, command palette, settings, menu bar extra  │
│  Features/       Containers · Images · Volumes · Networks · Builds · Machines · K8s · Reg │
│  Terminal/       SwiftTerm host view (spawns `container exec -it` / `machine run`)       │
└───────────────┬────────────────────────────────┬────────────────────────────────────────┘
                │ uses                           │ uses
┌───────────────▼───────────┐     ┌──────────────▼──────────────┐
│ AppCore (library)          │     │ DesignSystem (library)       │
│ stores (@Observable),      │     │ tokens, StatusDot, Badge,    │
│ polling, TaskCenter,       │     │ KeyValueGrid, EmptyState,    │
│ Settings, Diagnostics      │     │ LogView, ByteFormatters…     │
└───────────────┬───────────┘     └─────────────────────────────┘
                │ depends only on
┌───────────────▼─────────────────────────────────────────────────────────────────────────┐
│ ContainerKit (library)                                                                   │
│   Models/      Container, Image, Volume, Network, Stats, SystemStatus, Machine, Cluster… │
│   Backend/     protocols: SystemBackend, ContainerOperations, ImageOperations, …         │
│   CLI/         CLIBackend (ProcessRunner → /usr/local/bin/container … --format json)    │
│   Support/     CLIJSON (dates), JSONValue, TOML read/write, table parsers                │
└───────────────┬─────────────────────────────────────────────────────────────────────────┘
                │ implemented also by
┌───────────────▼───────────┐     ┌─────────────────────────────┐
│ ContainerKitMock           │     │ (future) ContainerKitXPC     │
│ MockBackend + fixtures     │     │ links apple/container's      │
│ recorded from CLI 1.5.0    │     │ ContainerAPIClient over XPC  │
└───────────────────────────┘     └─────────────────────────────┘
```

## Backend contract

`ContainerBackend` = `SystemBackend & ContainerOperations & ImageOperations & VolumeOperations & NetworkOperations
& RegistryOperations & MachineOperations & KubernetesOperations`. Every method is `async throws` and returns
domain models; long-running actions return `LineStream` (`AsyncThrowingStream<OutputLine, Error>`).
Errors are `BackendError` — the UI switches on `.systemNotRunning` / `.cliNotInstalled` to show full-screen states.

### CLIBackend (v1)

- Locates the binary: `CONTAINER_CLI` env (if executable) → `/usr/local/bin/container` → `/opt/homebrew/bin/container` (no `$PATH` lookup). Missing → `.cliNotInstalled`.
- `ProcessRunner` (actor): `Foundation.Process`, stdout/stderr pipes read on background tasks, cancellation
  kills the process group, timeouts, `--format json` where available, exit code → `BackendError.commandFailed`
  with stderr cleaned of progress lines (`[n/6] …`).
- Streaming: `logs -f`, `image pull`, `build --progress plain`, `k8s create` → line-by-line `OutputLine`s.
- Non-JSON commands parsed from tables: `k8s list`, `system dns ls`, `registry ls` (fallback), `system version`.
- Detects "apiserver not running" from stderr (`apiserver is not running`, `Plugins are unavailable` when
  `system status` fails) → `.systemNotRunning`.
- `createDNSDomain` runs `container system dns create` as admin via `osascript -e 'do shell script … with
  administrator privileges'`.
- Keeps no state; the stores cache.

### Why not XPC first?
Apple's `ContainerAPIClient` works for third parties (the server only checks the caller's UID), but pulls in the
entire `containerization` dependency graph (gRPC, NIO, protobuf) and couples us to Apple's internal Swift API
surface. The CLI contract (`--format json`) is the documented, version-stable surface. The protocol split lets an
XPC backend land later for lower latency without touching the UI.

## AppCore

- `AppModel` (`@MainActor @Observable`): owns the backend, `EngineState`, and child stores.
- Stores: `ContainersStore`, `ImagesStore`, `VolumesStore`, `NetworksStore`, `BuildsStore`, `MachinesStore`,
  `ClustersStore`, `RegistriesStore`, `SystemStore` (status, df, properties). Each exposes `items`, `isLoading`,
  `lastError`, `refresh()`, and action methods that call the backend then refresh.
- `Poller`: per-store interval, runs only while the view is visible (`onAppear/onDisappear`), backs off when the
  engine is down, resumes on app activation.
- `TaskCenter`: in-flight `LongRunningTask` (name, lines, progress, cancel) for pull/push/build/create; feeds the
  Activity panel + notifications.
- `SettingsStore`: `@AppStorage`-backed preferences + config.toml read/write via the backend.
- `Diagnostics`: collects versions, `system status`, last errors → text for bug reports.

## DesignSystem

Tokens (`Spacing`, `Radius`, semantic colors mapped to system colors), components: `StatusDot`, `StateBadge`,
`PlatformBadge`, `MetricTile`, `KeyValueGrid`, `EmptyStateView`, `ErrorBanner`, `OutputLogView` (fast
monospaced log with search), `ByteCount`/`RelativeDate` formatters, `ConfirmDestructive` modifier.

## App

- `NavigationSplitView`: sidebar (sections with counts) · content (tables) · detail (inspector).
- `Settings` scene with tabs; `MenuBarExtra` scene; `Window("Activity")`.
- Terminal: `SwiftTerm.LocalProcessTerminalView` wrapped in `NSViewRepresentable`, spawned from
  `backend.terminalCommand(for:)`; never constructs CLI arguments itself.
- Environment: `\.backend` (any ContainerBackend), `\.appModel`.

## Packaging

`make app` → `swift build -c release` → assemble `build/Container Desktop.app` (Info.plist from
`Resources/Info.plist.template`, icon from `Resources/AppIcon.icns`, SwiftTerm bundle), ad-hoc sign; `make dmg`
→ `create-dmg`-free `hdiutil` DMG; `make notarize` (needs Developer ID; env `SIGN_IDENTITY`, `NOTARY_PROFILE`).
CI: GitHub Actions on `macos-26` runner: build + test on PR; release workflow on tag `v*` builds DMG and attaches it.

## Testing

- `ContainerKitTests`: decoders vs fixtures, `RunSpec`/`BuildSpec` argument builders, `CLIBackend` parsers against
  recorded text, `ProcessRunner` with `/bin/echo`/`/bin/sh` scripts (streaming, exit codes, cancellation).
- `AppCoreTests`: stores against `MockBackend` (refresh, actions mutate, errors captured, poller lifecycle).
- Manual: `make run-mock` for UI work without a runtime; `make run` against the real engine.
