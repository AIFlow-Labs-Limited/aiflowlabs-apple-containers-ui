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
& RegistryOperations & MachineOperations & KubernetesOperations & KubernetesWorkloadOperations
& ContainerFileOperations`. Every method is `async throws` and returns
domain models; long-running actions return `LineStream` (`AsyncThrowingStream<OutputLine, Error>`).
Errors are `BackendError` — the UI switches on `.systemNotRunning` / `.cliNotInstalled` to show full-screen states.

### CLIBackend (v1)

- Locates the binary: `CONTAINER_CLI` env when set (authoritative: a wrong path is `.cliNotInstalled`, never a silent fallback) → else `/usr/local/bin/container` → `/opt/homebrew/bin/container` (no `$PATH` lookup). Missing → `.cliNotInstalled`.
- `ProcessRunner` (actor): `Foundation.Process`, stdout/stderr pipes read on background tasks, cancellation
  kills the process group, timeouts, `--format json` where available, exit code → `BackendError.commandFailed`
  with stderr cleaned of progress lines (`[n/6] …`).
- Streaming: `logs -f`, `image pull`, `build --progress plain`, `k8s create` / `cluster create` → line-by-line `OutputLine`s.
- Non-JSON commands parsed from tables: `k8s ls` (and `cluster list --nodes` for node sizes), `system dns ls`,
  `registry ls` (fallback), `system version`.
- Kubernetes commands are built from `KubernetesCapabilities`, detected from the plugin's own `--help` (command
  word `k8s` or `cluster`, workers, shared image store, `load-image`, JSON listing). See `docs/COMPATIBILITY.md`.
- Detects "apiserver not running" from stderr (`apiserver is not running`, `Plugins are unavailable` when
  `system status` fails) → `.systemNotRunning`.
- `createDNSDomain` runs `container system dns create` as admin via `osascript -e 'do shell script … with
  administrator privileges'`.
- Workloads (`KubernetesWorkloadOperations`): `container exec -- <control-plane node> kubectl --kubeconfig
  /etc/kubernetes/admin.conf …`, the `kubectl` and admin kubeconfig that are already in the node image. The Mac's
  `kubectl`, `~/.kube/config` and DNS domain are not involved, and the kubeconfig is only named, never read.
  `KubectlAction` builds both the argv that runs and the command the UI shows. One call per poll lists pods,
  deployments, services, nodes and namespaces; `ClusterWorkloadsStore` filters by namespace.
- Keeps no resource state; the stores cache. It remembers only the detected Kubernetes capabilities (until the
  CLI binary changes) and which containers are cluster nodes (CLI 1.7+ hides them from `container list`).

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
- `RestartSupervisor`: enforces the restart policy stored in a container's `AppLabel.restart` label (the runtime
  has none). It has no timer: `ContainersStore`'s poller hands it every fresh list, and the store tells it about
  stops and starts the user makes so those are not undone. With enforcement on, `AppModel` keeps a background
  client on the containers poller at 10 s.
- `Supervision/`: enforcement without the app. The executable has a windowless mode (`--supervise`, see
  `App/HeadlessSupervisor.swift`) that runs `BackgroundSupervisor`: the same `RestartSupervisor` around a
  `CLIBackend`, fed by one `container list` every 10 s (30 s when no container has a policy), ended by SIGTERM
  (`TerminationSignals`). `LaunchAgentSupervisionService` installs it as a per-user LaunchAgent
  (`~/Library/LaunchAgents`, loaded with `launchctl`); `SMAppService.agent` was tried first and does not survive
  an update of an ad-hoc signed app. `EnforcementClaim` makes sure only one process enforces: two `flock` files
  in `~/Library/Application Support/Container Desktop/Supervision/`, one held by the enforcer, one by the helper
  for as long as it lives; the app stands down while a helper is alive. `FileSupervisionState` (`state.json` in
  the same folder) carries the stops and engine stops made in the app to whichever process enforces. Tests and
  mock runs use neither file (`DefaultsSupervisionState` in `UserDefaults`, no claim).
- `SettingsStore`: `@AppStorage`-backed preferences + config.toml read/write via the backend.
- `Diagnostics`: collects versions, `system status`, last errors → text for bug reports.
- `UpdateChecker`: asks GitHub's `releases/latest` for the app and for `apple/container` through the injected
  `HTTPFetching` (at most once a day, switchable off, nothing identifying sent), compares with `SemanticVersion`,
  and exposes the offers as observable state. It never downloads or installs. `RuntimeSupport` is the one place
  the supported runtime range (minimum, tested up to) is defined.

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
→ `create-dmg`-free `hdiutil` DMG; `make notarize` (needs Developer ID; env `SIGN_IDENTITY`, `NOTARY_PROFILE`);
`make cask` renders the Homebrew cask from `packaging/homebrew/container-desktop.rb.in` and the DMG's sha256;
`scripts/install.sh` is the one-line installer for people without Homebrew (see `docs/release/RELEASING.md`).
CI: GitHub Actions on `macos-26` runner: build + test on PR; release workflow on tag `v*` builds DMG and attaches it.

## Testing

- `ContainerKitTests`: decoders vs fixtures, `RunSpec`/`BuildSpec` argument builders, `CLIBackend` parsers against
  recorded text, `ProcessRunner` with `/bin/echo`/`/bin/sh` scripts (streaming, exit codes, cancellation).
- `AppCoreTests`: stores against `MockBackend` (refresh, actions mutate, errors captured, poller lifecycle).
- Manual: `make run-mock` for UI work without a runtime; `make run` against the real engine.
