#!/bin/bash
# Records what `kubectl` prints inside a cluster's control-plane node, for the workloads decoders.
#
#   scripts/record-kubectl-fixtures.sh <cluster> [namespace] [pod]
#
# Writes into Sources/ContainerKitMock/Resources/cli-<container version>/:
#   kubectl-workloads.json     get pods,deployments,services,nodes,namespaces --all-namespaces -o json
#   kubectl-pod-events.json    get events -n <namespace> for <pod>   (when namespace and pod are given)
#   kubectl-not-found.txt      stderr of `get pod` for a pod that does not exist
#
# JSON is pretty-printed with sorted keys. Nothing here reads a kubeconfig, a secret or a token: only the
# resource kinds above are asked for, and none of them carries credentials.
set -euo pipefail

CLUSTER="${1:?usage: record-kubectl-fixtures.sh <cluster> [namespace] [pod]}"
NAMESPACE="${2:-}"
POD="${3:-}"
CLI="${CONTAINER_CLI:-container}"
VERSION="$("$CLI" --version | sed -E 's/.*version ([0-9.]+).*/\1/')"
OUT="$(cd "$(dirname "$0")/.." && pwd)/Sources/ContainerKitMock/Resources/cli-$VERSION"
mkdir -p "$OUT"

kubectl_in_node() {
    "$CLI" exec "$CLUSTER" kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"
}

pretty() {
    python3 -I -c 'import json, sys; json.dump(json.load(sys.stdin), sys.stdout, indent=2, sort_keys=True); print()'
}

echo "Recording kubectl output of cluster $CLUSTER (container $VERSION) into $OUT"
kubectl_in_node get pods,deployments,services,nodes,namespaces --all-namespaces -o json \
    | pretty > "$OUT/kubectl-workloads.json"
if [ -n "$NAMESPACE" ] && [ -n "$POD" ]; then
    kubectl_in_node get events -n "$NAMESPACE" \
        --field-selector "involvedObject.kind=Pod,involvedObject.name=$POD" -o json \
        | pretty > "$OUT/kubectl-pod-events.json"
fi
kubectl_in_node get pod cd-it-no-such-pod -n default -o json 2> "$OUT/kubectl-not-found.txt" >/dev/null || true
echo "Done."
