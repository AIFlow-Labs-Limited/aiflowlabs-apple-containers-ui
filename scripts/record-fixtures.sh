#!/usr/bin/env bash
# Re-record the CLI fixtures used by ContainerKitMock and the decoding tests.
#
#   scripts/record-fixtures.sh            # -> Sources/ContainerKitMock/Resources/cli-<version>/
#   scripts/record-fixtures.sh /tmp/out   # -> /tmp/out (dry run / inspection)
#
# Read-only: it only runs list/inspect/status commands. Inspect fixtures use the first existing resource of
# each kind; when none exists the old fixture is kept (a warning is printed). JSON is pretty-printed with
# sorted keys (python3) so diffs stay readable. Requires the container system to be running.
# Override the binary with CONTAINER_CLI=/path/to/container.
set -euo pipefail

CLI="${CONTAINER_CLI:-/usr/local/bin/container}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -x "$CLI" ]]; then
    echo "error: container CLI not found at $CLI (set CONTAINER_CLI)" >&2
    exit 1
fi

VERSION="$("$CLI" --version | sed -E 's/.*version ([^ ]+).*/\1/')"
OUT="${1:-$ROOT/Sources/ContainerKitMock/Resources/cli-$VERSION}"
mkdir -p "$OUT"

if ! "$CLI" system status >/dev/null 2>&1; then
    echo "error: the container system is not running (container system start)" >&2
    exit 1
fi

pretty() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.dump(json.load(sys.stdin), sys.stdout, indent=2, sort_keys=True); print()'
    else
        cat
    fi
}

# record <file> <args...> — JSON output, pretty-printed; written only when the command succeeds.
record() {
    local file="$1"; shift
    local tmp
    tmp="$(mktemp)"
    if "$CLI" "$@" 2>/dev/null | pretty >"$tmp" && [[ -s "$tmp" ]]; then
        mv "$tmp" "$OUT/$file"
        echo "  recorded $file  ($CLI $*)"
    else
        rm -f "$tmp"
        echo "  warning: '$CLI $*' failed; kept existing $file" >&2
    fi
}

# record_text <file> <args...> — table output, verbatim.
record_text() {
    local file="$1"; shift
    local tmp
    tmp="$(mktemp)"
    if "$CLI" "$@" >"$tmp" 2>/dev/null; then
        mv "$tmp" "$OUT/$file"
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

# Kubernetes plugin: `cluster` from CLI 1.6.1, `k8s` before. What gets recorded follows what the plugin's own
# help says it can do (the same checks KubernetesCapabilities.detect makes), never the version number.
#   <word>-help.txt, <word>-create-help.txt, <word>-list-help.txt[, <word>-load-image-help.txt]   help screens
#   k8s-list.txt                      `k8s ls` (1.5 / 1.6.0: one row per node)
#   cluster-list.txt                  `cluster list` (1.6.1: one row per node; 1.7+: one row per cluster)
#   cluster-list-nodes.txt            `cluster list --nodes`        (when the plugin has --nodes)
#   cluster-list.json                 `cluster list --format json`  (when the plugin has --format)
K8S_WORD=""
for word in cluster k8s; do
    if "$CLI" "$word" --help >/dev/null 2>&1; then K8S_WORD="$word"; break; fi
done
if [[ -n "$K8S_WORD" ]]; then
    record_text "$K8S_WORD-help.txt"        "$K8S_WORD" --help
    record_text "$K8S_WORD-create-help.txt" "$K8S_WORD" create --help
    record_text "$K8S_WORD-list-help.txt"   "$K8S_WORD" list --help
    plugin_help="$("$CLI" "$K8S_WORD" --help 2>/dev/null || true)"
    list_help="$("$CLI" "$K8S_WORD" list --help 2>/dev/null || true)"
    if grep -Eq '^  load-image( |$)' <<<"$plugin_help"; then
        record_text "$K8S_WORD-load-image-help.txt" "$K8S_WORD" load-image --help
    fi
    record_text "$K8S_WORD-list.txt" "$K8S_WORD" ls
    if grep -q -- '--nodes' <<<"$list_help"; then
        record_text "$K8S_WORD-list-nodes.txt" "$K8S_WORD" list --nodes
    fi
    if grep -q -- '--format' <<<"$list_help"; then
        record "$K8S_WORD-list.json" "$K8S_WORD" list --format json
    fi
else
    echo "  warning: Kubernetes plugin (cluster / k8s) unavailable; kept existing cluster fixtures" >&2
fi

container_id="$(first_id ls -a --format json)"
[[ -n "$container_id" ]] && record container-inspect.json inspect "$container_id" \
    || echo "  warning: no containers; kept existing container-inspect.json" >&2

image_ref="$(first_id image ls --format json)"
[[ -n "$image_ref" ]] && record image-inspect.json image inspect "$image_ref" \
    || echo "  warning: no images; kept existing image-inspect.json" >&2

volume_id="$(first_id volume ls --format json)"
[[ -n "$volume_id" ]] && record volume-inspect.json volume inspect "$volume_id" \
    || echo "  warning: no volumes; kept existing volume-inspect.json" >&2

network_id="$(first_id network ls --format json)"
[[ -n "$network_id" ]] && record network-inspect.json network inspect "$network_id" \
    || echo "  warning: no networks; kept existing network-inspect.json" >&2

echo "Done. Review with: git diff --stat -- '$OUT'"
if [[ "$OUT" == "$ROOT/Sources/ContainerKitMock/Resources/"* && "$VERSION" != "1.5.0" ]]; then
    echo "note: new CLI version — add Resources/cli-$VERSION to Package.swift and Fixtures.cliVersion." >&2
    echo "note: recorded cluster-*/stats files replace the hand-written Resources/cli-1.7.1-derived samples:" >&2
    echo "      point DerivedFixtures at cli-$VERSION and delete that folder (see its README.md)." >&2
fi
