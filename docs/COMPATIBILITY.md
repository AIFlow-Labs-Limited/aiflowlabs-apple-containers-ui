# CLI compatibility

Container Desktop drives Apple's `container` CLI. This page says which CLI releases it works with, what each
release changed for the app, and how the app copes.

> **Status, plainly.** The app was built and tested against a live **container 1.5.0** engine, and its recorded
> fixtures come from 1.5.0. Support for **1.6.0, 1.6.1 and 1.7.1** was implemented by reading Apple's source code
> at those tags and the 1.7.1 release notes. **It has not yet been run against a live 1.6 or 1.7 engine.** The
> samples the 1.7 tests use (`Sources/ContainerKitMock/Resources/cli-1.7.1-derived/`) were written from that source,
> not recorded. See [What still needs a live engine](#what-still-needs-a-live-engine).
>
> **Verified on a live 1.5.0 engine on 2026-11-12** (gated suites, `CONTAINER_DESKTOP_INTEGRATION=1 swift test
> --filter Integration`): Kubernetes capability detection and a cluster created, listed and deleted
> ([below](#kubernetes-on-cli-150-verified-live)); the Files tab, export and commit
> ([below](#files-tab-export-and-commit-on-cli-150)); compose import ([COMPOSE.md](COMPOSE.md#verified-on-a-live-engine)).

## How the app adapts

No part of the app compares version numbers. For Kubernetes it asks the installed CLI what it can do:

1. `container cluster --help`, and if that plugin does not exist, `container k8s --help`.
2. `container <word> create --help`: is there `--workers`, does it take `count=<n>,cpus=<n>,memory=<size>`
   groups, is there `--shared-image-store`?
3. `container <word> list --help`: is there `--format` (JSON) and `--nodes`?
4. Is `load-image` in the subcommand list, and does it have `--node`?

The answer is a `KubernetesCapabilities` value (`Sources/ContainerKit/Models/KubernetesCapabilities.swift`). The
backend caches it for as long as the `container` binary on disk stays the same, so upgrading the CLI while the app
is open is picked up on the next refresh. With the engine stopped the answer is "unknown" (asked again later),
never "no Kubernetes". Everything else follows from it: the command word in every preview and copyable command,
which options the create sheet enables, whether "Load Image" is offered, and how clusters are listed.

For stats the app simply uses `cpuUtilization` when the JSON has it.

## What each release changed

| CLI | What changed for the app | What the app does |
|---|---|---|
| **1.5.0** | Baseline. Kubernetes plugin is `container k8s` (`create`, `delete`, `ls`, `load-image`, `write-config`). `k8s ls` prints one table row per node (`CLUSTER NODE ROLE STATE CPUS MEMORY ADDR PORTS`, CLUSTER blank). Single-node clusters only. Stats JSON has cumulative `cpuUsageUsec` only. | Parses the node table into clusters. Workers and the shared image store are disabled in the create sheet with a one-line reason. "Load Image" is offered. CPU % is computed from two samples. Verified on a live engine. |
| **1.6.0** | `k8s create --workers <n>` (workers named `<cluster>-worker-<n>`). `k8s load-image --node <name>`. The node table fills in CLUSTER. | Detects `--workers` and enables a worker count. Sized worker groups and the shared image store stay disabled. The node table parser already handled a filled CLUSTER column and multi-node clusters. |
| **1.6.1** | Plugin renamed to `container cluster` (default cluster name `cluster-dev`). Same subcommands and table as 1.6.0, `load-image` included. | Detects the `cluster` word; previews, copyable commands and every backend call use it. The create sheet's default name follows the CLI's. |
| **1.7.1** | `cluster list` prints one row per **cluster** (`NAME NODES K8S VERSION STATE`); `--nodes` gives the per-node table; `--format json` gives cluster records with `configuration` (Kubernetes version, CNI, FQDN, `--rm`, shared image store, nodes) and `status` (`running` / `degraded` / `stopped`, per-node state). | Lists from the JSON (lenient: unknown states and missing keys never fail) and reads per-node CPU / memory from the `--nodes` table. The list and inspector show Kubernetes version, "Degraded (2 of 3 up)", workers and the shared image store. |
| | `load-image` removed. `cluster create --shared-image-store` lets nodes use the local image store instead. | "Load Image" is hidden. The create sheet has a shared image store toggle that shows Apple's security warning; the inspector says whether a cluster has it on and repeats the warning. |
| | `--workers` takes a number or repeatable `count=<n>,cpus=<n>,memory=<size>` groups. | The create sheet can add separately sized worker groups; default-sized workers are still sent as a plain number. |
| | `container list` hides cluster nodes (even with `--all`); `start` / `stop` / `kill` / `delete` report a node as not found. `inspect`, `logs`, `exec`, `stats` still work on nodes. | The backend adds the running node containers back to the container list by `container inspect`ing them, so they stay under "system containers" and image / network / volume "in use" checks and the system memory figure stay correct. A refused start / stop / kill / delete of a node explains that the node belongs to a cluster. As soon as the app sees a node in `container list` it knows the CLI lists nodes itself and adds nothing. |
| | Clusters created by an earlier CLI have no stored record and are **not listed** by `cluster list`. | Nothing the app can do: such clusters do not appear in the Kubernetes section. Their node containers (labelled with the old `k8s` plugin name) may still show among system containers. Delete and re-create them. |
| | Stats JSON gains `cpuUtilization` (fraction of one core, measured by the CLI over 2 s). | Used directly as the CPU figure, from the first sample. Older CLIs keep the two-sample calculation. |

## Kubernetes on CLI 1.5.0, verified live

Checked on 2026-11-12 against a running 1.5.0 engine by `Tests/ContainerKitTests/KubernetesIntegrationTests.swift`
(no DNS domain was registered on the Mac):

- `kubernetesCapabilities()` finds the `k8s` word (after `container cluster --help` fails with "unknown command")
  and reads the real help screens as: no `--workers`, no worker groups, no `--shared-image-store`, `load-image`
  without `--node`, no `--format`, no `--nodes`, default name `k8s-dev`. The cached answer and a fresh detection
  agree.
- `listClusters()` with no clusters returns an empty list (the table has a header row only).
- A spec with workers fails with `.unsupported` before any command runs.
- `createCluster` with `--name cd-it-… -c 2 -m 2G` and the local `kindest/node` image created a single-node
  cluster in about a minute. `listClusters()` then shows one running control-plane node with 2 CPUs, 2048 MB and
  an address; the node is a container the app files under system containers. `deleteCluster` removes the cluster
  and its node container.
- The plugin adds a context named after the cluster to `~/.kube/config` on create and removes it on delete.

Not checked: `load-image`, `write-config`, `--cni`, `--rm`, and reaching the API server with `kubectl`.

## Files tab, export and commit on CLI 1.5.0

Checked on 2026-11-12 against a running 1.5.0 engine, in a BusyBox container (`alpine`) and a GNU coreutils one
(`python:3.11-slim`), by `Tests/ContainerKitTests/CLIBackendFilesIntegrationTests.swift` and
`CLIBackendFileCopyIntegrationTests.swift`. What the runtime does, and what the app does about it:

| `container` 1.5.0 behaviour (observed) | What the app does |
|---|---|
| `container exec` of a program that is not in the image exits **1** (not 126 / 127) with `Error: failed to find target executable <name>`, followed by a second `Error: failed to start process …` line that repeats it. | The listing treats that text for `sh` as "this image has no shell" and offers Export instead. A missing tool other than `sh` is a normal command failure that names the tool. |
| `exec` and `cp` on a stopped container exit 1 with `container <id> is not running` (`cp` wraps it: `failed to copy from container <id> (cause: "invalidState: "container <id> is not running"")`). `export` works on a stopped container. | The Files tab asks for a running container and offers Start and Export Filesystem. |
| `container export -o <tar> <id>` writes a valid tar for running and stopped containers. It holds the root filesystem only: the contents of volumes, bind mounts and tmpfs are not in it. | Used as is. |
| `container cp` only sees the root filesystem. Copying **out** of a volume, bind mount, tmpfs, `/dev/shm` or `/proc` fails with `copy: path not found`. Copying **in** exits 0, but the file lands underneath the mount, where nothing in the container can see it. | Downloads from such a path are first copied to a temporary item in `/` inside the container (`cp -a`). Uploads to a mount go to a temporary item in `/` and are moved into place with `mv`. A direct upload is checked afterwards (`test -e`). |
| `cp <src> <id>:/existing-dir` puts the source *inside* the directory. | An upload to a path that exists goes to a temporary name, the old item is moved aside, the new one moved in, the old one removed. `/`, system directories and mount points are never replaced. |
| `cp` sends container paths in decomposed Unicode form. A precomposed `é` (how Linux tools store it) is "not found" on download; an upload creates a second, decomposed `é`. | Such paths are reached through an ASCII alias: a symbolic link in `/` for downloads, a temporary name plus `mv` for uploads. |
| Uploading a folder replaces every non-ASCII character in the names inside it with `*`. Downloading a folder keeps them. | The folder is uploaded with ASCII placeholder names, which are renamed back inside the container. |
| `cp` creates a missing parent directory of the destination. | Nothing; noted here. |
| `container commit` does not exist: `Error: unknown command 'commit'`, exit 64. | `supportsCommit()` is `false`, "Save as Image…" is unavailable, and a commit that is attempted anyway fails with "Save as Image is not available: … added in Apple container 1.6". |

One more thing the pass found is on the Mac side, not in the CLI: Foundation's `Process` passes arguments to a
child in decomposed Unicode form (`é` becomes `e` + combining accent, a Hangul syllable becomes its jamo). Every
`exec` on a path with such a character would therefore name a file that does not exist. The file operations send
those arguments as ASCII `printf` escapes and let `sh` in the container decode them. Other features that pass text
to a container (the Run sheet's environment values and commands) still go through `Process` unchanged, so an
accented character there arrives decomposed. It looks the same and compares differently.

The workarounds need `test`, `ln`, `cp`, `mv`, `rm` and, for non-ASCII names, `sh` in the image. A plain ASCII
path on the root filesystem that does not exist yet is copied directly and needs none of them.

## What still needs a live engine

Everything in the 1.6 and 1.7 rows above. In particular these are read from source, not observed:

- The exact text and layout of the plugin's `--help` screens (the app only looks for option names and the
  `count=<` syntax, so wording changes are harmless, but a renamed option is not).
- That `container cluster <sub> --help` works through the `container` binary the way `container k8s --help` does on 1.5.0.
- The JSON of `cluster list --format json`: key names, `null` for unset `cni` / `fqdn`, omitted `addresses` /
  `ports`, ISO 8601 dates without fractions, and that nothing else is printed on stdout.
- The `cluster list --nodes` table: column layout, `8 GB`-style memory (it comes from `ByteCountFormatter`, which
  is locale-dependent; the app reads CPU / memory as 0 and shows "—" if it cannot parse a cell).
- That `container inspect <node>` returns a cluster node in the same JSON shape as other containers, and what
  `container stop <node>` prints when it refuses.
- That `container stats -- <node>` returns figures for a node that `container list` hides.
- `cpuUtilization` being present for every container in `stats --no-stream --format json`.
- Creating a cluster with worker groups and with `--shared-image-store`, end to end.

Only Kubernetes and stats were compared between releases. Other commands (`run`, `build`, `image`, `volume`,
`network`, `machine`, `system`) were not audited for 1.6 / 1.7 changes.

## When a 1.7 engine is available

```bash
scripts/record-fixtures.sh     # writes Sources/ContainerKitMock/Resources/cli-<version>/
```

The script records the help screens, `cluster list` (table, `--nodes`, JSON) and stats for whatever the installed
plugin supports. Replace `cli-1.7.1-derived/` with the recording (its `README.md` lists the steps), run `make check`,
then walk through the list above with `make run`.

## Trying the 1.7 behaviour without a 1.7 engine

```bash
make app
CONTAINER_DESKTOP_MOCK_CLI=1.7 open "build/Container Desktop.app" --env CONTAINER_DESKTOP_BACKEND=mock --env CONTAINER_DESKTOP_MOCK_CLI=1.7
```

`MockBackend` then plays a 1.7-style `cluster` plugin seeded with the derived samples (a running, a degraded and a
stopped cluster). Without the variable it plays 1.5.0, and `CONTAINER_DESKTOP_MOCK_CLI=none` plays a CLI without the plugin.
