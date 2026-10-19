#!/usr/bin/env bash
# Install the local git hooks. CI is manual-only for this repo; `make check` runs before every push instead.
#
#   scripts/install-hooks.sh          # install (idempotent)
#   scripts/install-hooks.sh --remove # uninstall
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_DIR="$(git -C "$ROOT" rev-parse --git-path hooks)"
HOOK="$HOOK_DIR/pre-push"

if [[ "${1:-}" == "--remove" ]]; then
    rm -f "$HOOK"
    echo "removed $HOOK"
    exit 0
fi

mkdir -p "$HOOK_DIR"
cat > "$HOOK" <<'EOF'
#!/usr/bin/env bash
# pre-push: run the full local gate (build + tests + strict lint). Skip once with SKIP_CHECK=1 git push.
set -euo pipefail
if [[ "${SKIP_CHECK:-}" == "1" ]]; then
    echo "pre-push: SKIP_CHECK=1, skipping make check" >&2
    exit 0
fi
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
echo "pre-push: make check" >&2
make check
EOF
chmod +x "$HOOK"
echo "installed $HOOK (runs 'make check' before every push; SKIP_CHECK=1 to bypass once)"
