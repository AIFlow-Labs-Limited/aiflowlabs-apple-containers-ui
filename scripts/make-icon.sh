#!/usr/bin/env bash
# Regenerate Resources/AppIcon.icns from scripts/make-icon.swift.
#
# Usage: scripts/make-icon.sh [OUT_ICNS]   (default: Resources/AppIcon.icns)
# The intermediate iconset lives in a temp dir; Resources/AppIcon.png (512 px) is kept for the README.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="${1:-Resources/AppIcon.icns}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
MASTER="$WORK/icon_1024.png"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> rendering master"
swift scripts/make-icon.swift "$MASTER"

echo "==> building iconset"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$MASTER" --out "$ICONSET/icon_${s}x${s}.png" > /dev/null
    d=$((s * 2))
    sips -z "$d" "$d" "$MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png" > /dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
sips -z 512 512 "$MASTER" --out Resources/AppIcon.png > /dev/null
echo "==> wrote $OUT and Resources/AppIcon.png"
