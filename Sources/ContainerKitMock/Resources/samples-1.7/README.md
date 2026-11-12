# samples-1.7: hand-written scenarios, NOT recordings

The recorded truth for container 1.7.1 is `../cli-1.7.1/` (written by `scripts/record-fixtures.sh` on 2026-11-12
from a live engine). Decoder and capability tests read that folder.

This folder keeps three invented clusters in the same shape, because one engine rarely shows all of these at
once and the mock (`CONTAINER_DESKTOP_MOCK_CLI=1.7`), the previews and the presentation tests want them side by
side:

| Cluster | What it shows |
|---|---|
| `cluster-dev` | one node that is both control plane and worker, running |
| `staging` | control plane and two workers, one worker stopped (`degraded`), shared image store on |
| `temp` | stopped, created with `--cni NONE` |

Names, addresses, sizes and dates are made up. The files were first written from Apple's source code (before a
1.7 engine was available) and were compared with the recording afterwards:

- Key names, `null` for an unset `cni`, omitted `addresses` / `ports` for a node that is down, ISO 8601 dates
  without fractions, one compact line with sorted keys: all as recorded.
- A node that is both control plane and worker has roles `control-plane,worker` (`cluster-list-single.*`).
- A stopped node whose container still exists keeps its CPUS and MEMORY cells in `cluster list --nodes`
  (`cluster-list-nodes-stopped.txt`). A node of a `--rm` cluster is removed when it stops, and then the cells
  are blank (`cluster-list-nodes-removed.txt`), as in the `temp` row here.

`Tests/ContainerKitTests/RecordedCLI171Tests.swift` fails if a sample uses a JSON key the recording does not have.
