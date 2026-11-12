#!/usr/bin/env bash
# Re-record the CLI fixtures used by ContainerKitMock and the decoding tests.
#
#   scripts/record-fixtures.sh            # -> Sources/ContainerKitMock/Resources/cli-<version>/
#   scripts/record-fixtures.sh /tmp/out   # -> /tmp/out (dry run / inspection)
#
# Read-only: it only runs list/inspect/status/--help commands. Inspect fixtures use the first existing resource
# of each kind; when none exists the old fixture is kept (a warning is printed). JSON is pretty-printed with
# sorted keys (python3) so diffs stay readable. Requires the container system to be running.
# Override the binary with CONTAINER_CLI=/path/to/container.
#
# Nothing is created for you: what exists on the engine is what gets recorded. For a useful set, have a running
# container with a published port, a volume and a network alias, a machine, and a cluster with a worker.
#
#   RECORD_CONTAINER=<id>           container for container-inspect.json (default: the first one listed)
#   RECORD_CLUSTER_VARIANT=<word>   record ONLY the cluster listings, as cluster-list-<word>.{txt,json} and
#                                   cluster-list-nodes-<word>.txt (e.g. `degraded`, after a node went down)
#   RECORD_IGNORE=<regex>           drop list elements whose id matches (e.g. another job's throwaway
#                                   containers on a shared engine); everything else is recorded as printed
#
# Privacy: `registry ls` user names and the account in `machine inspect` are replaced with `user`. Paths under
# the engine's application-support folder are kept as the CLI prints them (as in the 1.5.0 recording).
set -euo pipefail

CLI="${CONTAINER_CLI:-/usr/local/bin/container}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -x "$CLI" ]]; then
    echo "error: container CLI not found at $CLI (set CONTAINER_CLI)" >&2
    exit 1
fi

VERSION="$("$CLI" --version | sed -E 's/.*version ([^ ]+).*/\1/')"
OUT="${1:-$ROOT/Sources/ContainerKitMock/Resources/cli-$VERSION}"
NEW_FOLDER=0
[[ -d "$OUT" ]] || NEW_FOLDER=1
mkdir -p "$OUT"

if ! "$CLI" system status >/dev/null 2>&1; then
    echo "error: the container system is not running (container system start)" >&2
    exit 1
fi

pretty() {
    if command -v python3 >/dev/null 2>&1; then
        RECORD_IGNORE="${RECORD_IGNORE:-}" python3 -c '
import json, os, re, sys
value = json.load(sys.stdin)
ignore = os.environ.get("RECORD_IGNORE")
if ignore and isinstance(value, list):
    value = [v for v in value if not (isinstance(v, dict) and re.search(ignore, str(v.get("id", ""))))]
json.dump(value, sys.stdout, indent=2, sort_keys=True); print()
'
    else
        cat
    fi
}

# Replaces account names (`username`, `user`) with `user` and a `home` path with `/home/user`, then pretty-prints.
scrub() {
    python3 -c '
import json, sys
def scrub(value):
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if key in ("username", "user") and isinstance(item, str):
                out[key] = "user"
            elif key == "home" and isinstance(item, str):
                out[key] = "/home/user"
            else:
                out[key] = scrub(item)
        return out
    if isinstance(value, list):
        return [scrub(item) for item in value]
    return value
json.dump(scrub(json.load(sys.stdin)), sys.stdout, indent=2, sort_keys=True); print()
'
}

# record_through <filter> <file> <args...> — stdout piped through <filter>; written only on success.
record_through() {
    local filter="$1" file="$2"; shift 2
    local tmp
    tmp="$(mktemp)"
    if "$CLI" "$@" 2>/dev/null | "$filter" >"$tmp" && [[ -s "$tmp" ]]; then
        chmod 644 "$tmp" && mv "$tmp" "$OUT/$file"
        echo "  recorded $file  ($CLI $*)"
    else
        rm -f "$tmp"
        echo "  warning: '$CLI $*' failed; kept existing $file" >&2
    fi
}

# record <file> <args...> — JSON output, pretty-printed.
record() { record_through pretty "$@"; }

# record_scrubbed <file> <args...> — JSON output with account names replaced, pretty-printed.
record_scrubbed() { record_through scrub "$@"; }

# record_text <file> <args...> — stdout verbatim (tables, help screens, or JSON as the one line the CLI prints).
record_text() {
    local file="$1"; shift
    local tmp
    tmp="$(mktemp)"
    if "$CLI" "$@" >"$tmp" 2>/dev/null; then
        chmod 644 "$tmp" && mv "$tmp" "$OUT/$file"
        echo "  recorded $file  ($CLI $*)"
    else
        rm -f "$tmp"
        echo "  warning: '$CLI $*' failed; kept existing $file" >&2
    fi
}

# first_id <json-list-args...> — prints the first element's id (or configuration.name for images).
first_id() {
    "$CLI" "$@" 2>/dev/null | python3 -c '
import json, sys
items = json.load(sys.stdin)
if items:
    item = items[0]
    print(item.get("configuration", {}).get("name") if "variants" in item else item.get("id", ""))
' 2>/dev/null || true
}

# Kubernetes plugin: `cluster` from CLI 1.6.1, `k8s` before. What gets recorded follows what the plugin's own
# help says it can do (the same checks KubernetesCapabilities.detect makes), never the version number.
#   <word>-help.txt, <word>-create-help.txt, <word>-list-help.txt[, <word>-load-image-help.txt]   help screens
#   k8s-list.txt                      `k8s ls` (1.5 / 1.6.0: one row per node)
#   cluster-list.txt                  `cluster list` (1.6.1: one row per node; 1.7+: one row per cluster)
#   cluster-list-nodes.txt            `cluster list --nodes`        (when the plugin has --nodes)
#   cluster-list.json                 `cluster list --format json`  (when the plugin has --format)
#   cluster-list.compact.json         the same, byte for byte as printed (one line)
#   cluster-node-inspect.json         `container inspect <nodes of the first cluster>` (JSON-capable plugins)
K8S_WORD=""
for word in cluster k8s; do
    if "$CLI" "$word" --help >/dev/null 2>&1; then K8S_WORD="$word"; break; fi
done

# record_cluster_lists <suffix> — the listings the installed plugin supports, as <word>-list<suffix>.*.
record_cluster_lists() {
    local suffix="$1" list_help
    list_help="$("$CLI" "$K8S_WORD" list --help 2>/dev/null || true)"
    record_text "$K8S_WORD-list$suffix.txt" "$K8S_WORD" ls
    if grep -q -- '--nodes' <<<"$list_help"; then
        record_text "$K8S_WORD-list-nodes$suffix.txt" "$K8S_WORD" list --nodes
    fi
    if grep -q -- '--format' <<<"$list_help"; then
        record "$K8S_WORD-list$suffix.json" "$K8S_WORD" list --format json
        record_text "$K8S_WORD-list$suffix.compact.json" "$K8S_WORD" list --format json
    fi
}

if [[ -n "${RECORD_CLUSTER_VARIANT:-}" ]]; then
    if [[ -z "$K8S_WORD" ]]; then
        echo "error: no Kubernetes plugin (cluster / k8s) to record from" >&2
        exit 1
    fi
    echo "Recording CLI $VERSION cluster listings (variant: $RECORD_CLUSTER_VARIANT) into $OUT"
    record_cluster_lists "-$RECORD_CLUSTER_VARIANT"
    exit 0
fi

echo "Recording CLI $VERSION fixtures into $OUT"

record containers.json        ls -a --format json
record images.json            image ls --format json
record volumes.json           volume ls --format json
record networks.json          network ls --format json
record machines.json          machine ls --format json
record stats.json             stats --no-stream --format json
record builder.json           builder status --format json
record system-df.json         system df --format json
record system-properties.json system property ls --format json
record system-status.json     system status --format json
record_text system-status.txt  system status
record_text system-version.txt system version
record_scrubbed registries.json registry ls --format json

# Top-level help: which subcommands exist (`commit` from 1.6, `clean` from 1.7). The capability tests read these.
record_text help.txt --help
root_help="$("$CLI" --help 2>/dev/null || true)"
for sub in commit clean; do
    if grep -Eq "^  $sub( |\$)" <<<"$root_help"; then record_text "$sub-help.txt" "$sub" --help; fi
done

if [[ -n "$K8S_WORD" ]]; then
    record_text "$K8S_WORD-help.txt"        "$K8S_WORD" --help
    record_text "$K8S_WORD-create-help.txt" "$K8S_WORD" create --help
    record_text "$K8S_WORD-list-help.txt"   "$K8S_WORD" list --help
    plugin_help="$("$CLI" "$K8S_WORD" --help 2>/dev/null || true)"
    if grep -Eq '^  load-image( |$)' <<<"$plugin_help"; then
        record_text "$K8S_WORD-load-image-help.txt" "$K8S_WORD" load-image --help
    fi
    record_cluster_lists ""
    node_names="$("$CLI" "$K8S_WORD" list --format json 2>/dev/null | python3 -c '
import json, sys
clusters = json.load(sys.stdin)
if clusters:
    print(" ".join(node["name"] for node in clusters[0]["configuration"]["nodes"]))
' 2>/dev/null || true)"
    if [[ -n "$node_names" ]]; then
        # shellcheck disable=SC2086  # node names are container ids: no spaces
        record cluster-node-inspect.json inspect $node_names
    fi
else
    echo "  warning: Kubernetes plugin (cluster / k8s) unavailable; kept existing cluster fixtures" >&2
fi

container_id="${RECORD_CONTAINER:-$(first_id ls -a --format json)}"
[[ -n "$container_id" ]] && record container-inspect.json inspect "$container_id" \
    || echo "  warning: no containers; kept existing container-inspect.json" >&2

image_ref="$(first_id image ls --format json)"
[[ -n "$image_ref" ]] && record image-inspect.json image inspect "$image_ref" \
    || echo "  warning: no images; kept existing image-inspect.json" >&2

volume_id="$(first_id volume ls --format json)"
[[ -n "$volume_id" ]] && record volume-inspect.json volume inspect "$volume_id" \
    || echo "  warning: no volumes; kept existing volume-inspect.json" >&2

machine_id="$(first_id machine ls --format json)"
[[ -n "$machine_id" ]] && record_scrubbed machine-inspect.json machine inspect "$machine_id" \
    || echo "  warning: no machines; kept existing machine-inspect.json" >&2

network_id="$(first_id network ls --format json)"
[[ -n "$network_id" ]] && record network-inspect.json network inspect "$network_id" \
    || echo "  warning: no networks; kept existing network-inspect.json" >&2

echo "Done. Review with: git diff --stat -- '$OUT'"
if [[ "$NEW_FOLDER" == 1 && "$OUT" == "$ROOT/Sources/ContainerKitMock/Resources/"* ]]; then
    echo "note: new CLI version: add Resources/cli-$VERSION to Package.swift and a loader next to Fixtures." >&2
fi
