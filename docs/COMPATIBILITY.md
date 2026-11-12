# CLI compatibility

Container Desktop drives Apple's `container` CLI. This page says which CLI releases it works with, what each
release changed for the app, and how the app copes.

> **Status, plainly.** The app was built against a live **container 1.5.0** engine. Support for **1.6.0, 1.6.1
> and 1.7.1** was first written from Apple's source code at those tags.
>
> **Verified on a live 1.7.1 engine on 2026-11-12** (macOS 27.2, the gated suites,
> `CONTAINER_DESKTOP_INTEGRATION=1 swift test --filter Integration`): everything in the 1.7.1 rows below, with
> recorded fixtures in `Sources/ContainerKitMock/Resources/cli-1.7.1/`. Details and the short list of what could
> not be checked are in [Verified on a live 1.7.1 engine](#verified-on-a-live-171-engine).
>
> **Verified on a live 1.5.0 engine on 2026-11-12**, before that Mac was upgraded: Kubernetes capability
> detection and a cluster created, listed and deleted ([below](#kubernetes-on-cli-150-verified-live)); the Files
> tab, export and commit ([below](#files-tab-export-and-commit-on-cli-150)); compose import
> ([COMPOSE.md](COMPOSE.md#verified-on-a-live-engine)).
>
> **1.6.0 and 1.6.1 have never been installed.** Their rows are still read from source only. The same code paths
> run on 1.5.0 and 1.7.1, which are both verified, but the 1.6 help screens and its `--workers <n>` /
> `load-image --node` have not been seen live.

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


## Verified on a live 1.7.1 engine

Checked on 2026-11-12 against `container` 1.7.1 (commit a15b460) on macOS 27.2, Apple silicon. The DNS property
`dns.domain` was `test`, but no macOS resolver was registered for it (`container system dns ls` was empty, and
registering one needs an administrator password). Every item names the gated test that proves it; the tests
decide what to check from the CLI's `--help`, so they pass or return early on 1.5.0 as well.

| What | Observed on 1.7.1 | Proven by |
|---|---|---|
| Capability detection | `container cluster --help` works through the `container` binary. The real help screens are detected as: `cluster`, `--workers` with `count=<n>,cpus=<n>,memory=<size>` groups, `--shared-image-store`, `--format`, `--nodes`, no `load-image`, default name `cluster-dev`. `container commit --help` exits 0. | `KubernetesIntegrationTests.detectsThePluginOfTheInstalledCLI`; `RecordedCLI171Tests` (recorded help as fixtures) |
| `cluster create` with a worker group | `--name N -c 2 -m 2G --workers count=1,cpus=2,memory=2G --shared-image-store` creates a control plane and `N-worker-1` in about 70 s and streams its progress. | `KubernetesIntegrationTests.createsAClusterWithASizedWorkerGroup` |
| `cluster list --format json` | One compact line, nothing else on stdout. Keys are exactly the ones the model mirrors; `cni` is an explicit `null`; `fqdn` is `<name>.<dns.domain>`; dates are ISO 8601 without fractions; a node that is down has no `addresses` key; `ports` is absent when an FQDN is set. A single node has roles `["control-plane","worker"]`. | same test; `RecordedCLI171Tests` |
| `cluster list --nodes` | `CLUSTER NODE ROLE STATE CPUS MEMORY ADDR PORTS`, memory as `2 GB`. A stopped node keeps its CPUS / MEMORY; a node of a `--rm` cluster is removed when it stops and then both cells are blank (the cluster stays listed as `stopped`). | same test; `RecordedCLI171Tests.singleNodeClusterAndItsRemovedNode` |
| Degraded state | With one of two nodes down: `status.state` is `degraded`, the table says `degraded (1 of 2 up)`, which is the app's wording too. | same test (it powers the worker off from the inside) |
| Shared image store | A pod ran an image that existed only as a local tag, without `load-image`. | same test (`kubectl` inside the control-plane node) |
| Nodes and `container list` | `container list --all` leaves cluster nodes out; `inspect`, `logs`, `exec`, `cp` and `stats` work on them, and `stats` without ids includes them. The app adds running nodes back, so they show under system containers. `start` / `stop` / `kill` / `delete` of a node print `container with ID <node> not found`, which the app turns into "belongs to the Kubernetes cluster". A node that is down is not added back, even with stopped containers shown. | same test |
| kubeconfig | `create` adds a context named after the cluster to `~/.kube/config` and makes it the current context. `delete` removes it; the file was byte-identical to before afterwards (it had no other contexts). | same test |
| `cluster delete` | Works for running, degraded and stopped clusters and removes the node containers. | both cluster tests |
| Workloads (`kubectl` inside the control-plane node) | The node image (`kindest/node:v1.35.5`) has `/usr/bin/kubectl` and kubeadm's `/etc/kubernetes/admin.conf`, so `container exec -- <cluster> kubectl --kubeconfig /etc/kubernetes/admin.conf …` reaches the API server with no `kubectl`, kubeconfig or DNS domain on the Mac. One `get pods,deployments,services,nodes,namespaces --all-namespaces -o json` takes well under a second. On a fresh single-node cluster: the system pods, the node and the `kubernetes` service are listed; a two-replica deployment and a ClusterIP service appear with `2/2` and `80/TCP`; `logs` (whole, followed and cancelled, `--previous` failing for a container that never restarted), pod events, `scale --replicas=3`, `rollout restart` (all pods replaced) and `delete pod` (replaced by the deployment) work; a second delete is kubectl's `NotFound`. A cancelled `logs --follow` leaves no `kubectl` behind in the node. A crash-looping pod alternates between `Error` and `CrashLoopBackOff` in the STATUS column, as in `kubectl get pods`. | `WorkloadsIntegrationTests.listsLogsScalesRestartsAndDeletes`; `KubeWorkloadsDecodingTests` (recorded `kubectl` JSON as fixtures) |
| `commit` (Save as Image) | `container commit -- ID REF` works on running and stopped containers and prints `docker.io/library/<ref>`. The image is listed and runs. The container's process becomes the image's `Entrypoint` (executable) and `Cmd` (arguments) and its labels are copied, so the image runs the same process by default. Volume contents are not included. | `CLIBackendImageIntegrationTests.commitSavesAnImageThatIsListedAndRuns` |
| Stats | Rows of `stats --no-stream --format json` have `cpuUtilization` (a busy single-core loop read between 0.2 and 1.5). One call takes about 2 s. A container that stops during those 2 s is listed without the key; the app then falls back to its two-sample calculation for that row. | `CLIBackendImageIntegrationTests.statsDecodeWithOrWithoutCPUUtilization` |
| `image save` / `image load` | One platform saves to an OCI tar and loads back. See the note on "All platforms" below. | `CLIBackendImageIntegrationTests.savesAnImageToATarAndLoadsItBack` |
| Machines | `machine create --no-boot`, `machine ls --format json`, `machine inspect`, `machine rm`: same JSON as 1.5.0. | `CLIBackendImageIntegrationTests.machineCreatedWithoutBootIsListedInspectedAndDeleted` |
| `build` | Still a plugin; its step lines arrive while the build runs, not at the end. | `CLIBackendImageIntegrationTests.buildStreamsItsProgress`, `ComposeBuildIntegrationTests` |
| `cp`, `export`, `exec`, Files tab | Behave as described for 1.5.0 above. | `CLIBackendFilesIntegrationTests`, `CLIBackendFileCopyIntegrationTests`, `CLIBackendExportIntegrationTests` |
| Volumes, networks, registry list, `system` commands | Same JSON shapes as 1.5.0. `registry ls --format json` is `[]` with no logins (a login was not tried). | `CLIBackendIntegrationTests.readOnlyListings`, `ComposeIntegrationTests`, `RecordedCLI171Tests` |

### What 1.7.1 changed outside Kubernetes

Compared with the 1.5.0 recording, key by key:

- **`container inspect` / `container list`**: no new keys except `configuration.platform.variant` (`v8`).
  There is still **no exit code, no restart count or policy and no health status**: a container that exited with
  status 3 reports only `"state": "stopped"` and `startedDate`. `container run` has no `--restart` or
  `--health-*` options. The app's own restart policies and compose health waits stay necessary.
- **Network aliases**: `--network <net>,alias=<name>` is stored as `<name>.<dns.domain>` in
  `configuration.networks[].options.aliases`. Passing the stored, fully qualified form back gives the same
  value (not a doubled suffix), so re-running a container from its inspect data is safe, and a duplicate alias is
  refused (`alias(es) already exist`). Whether the alias resolves could not be checked without a registered DNS
  domain.
- **Stats**: `cpuUtilization` added.
- **System properties**: a new, empty `container.dns` group. Builder image 0.13.3, init image 0.54.0.
- **Images**: same shape. The cluster node image is stored by digest, without a tag
  (`docker.io/kindest/node@sha256:…`), and shows as `<none>` in `container image ls`.
- **Volumes, networks, machines, `system df`, `system status`, builder**: unchanged.
- **`machine create`** gained `--user`, `--uid`, `--gid` and `--home`. The app does not pass them.
- **`container clean`** is new: see below.

### Found on the live engine

- `container image save` without `--platform` saves every platform in the image's index. For an image that was
  pulled for this Mac only, the CLI fails with just `content with digest sha256:…`. The Save sheet's default is
  "All platforms", so this is easy to hit. The app now completes the message and tells you to choose a single
  platform. (Whether 1.5.0 does the same was not checked.)
- `container commit` reports a missing container as `get failed: container <id> not found`, a wording the app
  did not recognise as "not found". It does now.
- The plugin help ends its SUBCOMMANDS list with a sentence indented like a command; the help parser took it for
  a subcommand name. Harmless (nothing looked that name up), fixed anyway.

### `container clean`

`container clean <id>…` "cleans unused space on the root filesystem and each named volume mount" of running
containers (Apple's command reference; it fails for a container that is not running). It deletes nothing.
Container Desktop does not call it and nothing in the app depends on the list of top-level commands, so its
arrival changes nothing. It was not run during this pass.

### Still not verified

- **1.6.0 and 1.6.1**: never installed. Their help screens in the tests are still written from source.
- `--workers <n>` as a plain number (1.7.1's help documents it; only the `count=…` form was run).
- `--cni <file>` / `--cni NONE`, and `cluster write-config`.
- Reaching the API server with `kubectl` from the Mac: the kubeconfig server is `https://<cluster>.test:6443`,
  which needs a registered DNS domain. Without one `kubectl` fails with "no such host" (seen), which is what the
  cluster inspector warns about.
- That clusters created by an earlier CLI are not listed (the 1.5.0 test clusters were deleted before the
  upgrade).
- `registry login` / `logout`, and `image push`.
- The workloads view on anything but 1.7.1. It only needs `container exec` on the control-plane node and a node
  image that contains `kubectl`, which 1.5.0's clusters also had, but it was not run there. A node image without
  `kubectl` (a custom `--node-image`) shows "not available" with the reason. Multi-container pods and init
  containers are covered by hand-written tests only; the recorded cluster had single-container pods.
- Whether `create` restores the previous current context of a kubeconfig that already had one.

## Fixtures

```bash
scripts/record-fixtures.sh     # writes Sources/ContainerKitMock/Resources/cli-<version>/
```

| Folder | What it is |
|---|---|
| `cli-1.5.0/` | Recorded from 1.5.0. `MockBackend` and most decoder tests are built on it (`Fixtures`). |
| `cli-1.7.1/` | Recorded from 1.7.1 on 2026-11-12 (`FixtureSet.cli171`): JSON listings and inspects, the help screens the detectors read, a two-node cluster running, degraded and stopped, and a one-node `--rm` cluster before and after its node went away. |
| `samples-1.7/` | Three hand-written cluster scenarios in the recorded shape, for the mock and the presentation tests. Not recordings; see its `README.md`. |

The script only runs list, inspect, status and `--help` commands; it records whatever exists on the engine. It
replaces registry user names and the account in `machine inspect` with `user`. Paths under the engine's
application-support folder are kept as printed, as in the 1.5.0 recording.

## Trying the 1.7 behaviour without a 1.7 engine

```bash
make app
CONTAINER_DESKTOP_MOCK_CLI=1.7 open "build/Container Desktop.app" --env CONTAINER_DESKTOP_BACKEND=mock --env CONTAINER_DESKTOP_MOCK_CLI=1.7
```

`MockBackend` then plays a 1.7-style `cluster` plugin seeded with the three sample scenarios (a running, a
degraded and a stopped cluster). Without the variable it plays 1.5.0, and `CONTAINER_DESKTOP_MOCK_CLI=none` plays a
CLI without the plugin.
