# cli-1.7.1-derived: NOT recorded

Every file in this folder was **written by hand from Apple's container 1.7.1 source code**, not recorded from a
running CLI. The Mac this app is developed on still had container 1.5.0 when 1.6/1.7 support was added, so there
was nothing to record from.

They exist so the decoders, the capability detection and the mock backend have something 1.7-shaped to work
with. `CLAUDE.md` rule 4 ("fixtures are truth") still stands: **replace this folder with real recordings** as
soon as a 1.7.x engine is available:

```bash
scripts/record-fixtures.sh        # writes Sources/ContainerKitMock/Resources/cli-<version>/
```

then point `DerivedFixtures` (Sources/ContainerKitMock/DerivedFixtures.swift) at the recorded folder, delete
this one, and update `Package.swift`.

## What each file was derived from (apple/container tag 1.7.1)

| File | Derived from |
|---|---|
| `cluster-list.json` | `ClusterResource`, `ClusterConfiguration`, `ClusterStatus` (`Sources/ContainerResource/Cluster/`) and `ClusterService.resources` (how `status` is computed). Pretty-printed with sorted keys, as `scripts/record-fixtures.sh` stores recordings. |
| `cluster-list.compact.json` | The same payload as the single line the CLI prints: `Output.renderJSON(_, options: .compact)` in `Sources/ContainerResource/Output/OutputRendering.swift`. |
| `cluster-list.txt` | `ClusterResource: ListDisplayable` in `Sources/ContainerCluster/ClusterHelper.swift` (`NAME NODES K8S VERSION STATE`). |
| `cluster-list-nodes.txt` | `ClusterNodeRow` + `ClusterHelper.buildNodeRows` (same file) and `TableOutput` (`Sources/ContainerCluster/Support/TableOutput.swift`). |
| `cluster-help.txt`, `cluster-create-help.txt`, `cluster-list-help.txt` | The ArgumentParser declarations in `Sources/Plugins/Cluster/ClusterCommand.swift` and `Sources/ContainerCluster/Commands/Cluster{Create,List}.swift`, laid out like the real 1.5.0 help screens in `../cli-1.5.0/k8s-*-help.txt`. |
| `stats.json` | `StatsReport` in `Sources/ContainerCommands/Container/ContainerStats.swift` and the sample in `docs/resource-usage.md`. |

## Encoder details that were mirrored

- JSON keys are sorted (`.sortedKeys`), slashes are not escaped, and the CLI prints one line (no pretty-printing).
- Dates use `.iso8601`: `2026-11-10T09:14:07Z`, no fractional seconds.
- `configuration.cni` and `configuration.fqdn` are written as explicit `null` when unset (`ClusterConfiguration.encode`).
- `status.nodes[].addresses` and `.ports` are **left out** when the node has none (synthesized `encodeIfPresent`).
- `configuration.labels` is a plain string dictionary (`{}` when empty); `nodes[].kind` is `"linux"`.
- `status.state` is `running` (all nodes up), `degraded` (some), `stopped` (none); a node whose container is gone
  is reported with `"status": "stopped"`.
- Tables pad every column except the last to the widest cell plus two spaces, so rows with empty trailing cells
  end in spaces. Memory in the node table is `ByteCountFormatter` with `.memory` style (`8 GB`, `512 MB`), and
  CPUS / MEMORY are blank when the node's container no longer exists.
- With a DNS domain configured (`fqdn` set) the control plane publishes no host port, so PORTS is empty.

## Known guesses

- The exact wording and line wrapping of the three help files (the option names and descriptions are from the
  source; the layout is ArgumentParser's, reproduced by hand).
- Sample values (names, addresses, sizes, dates) are invented.
