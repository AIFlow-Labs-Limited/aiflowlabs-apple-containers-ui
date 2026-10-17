#!/usr/bin/env bash
# Package the built .app into a compressed, verified DMG with an /Applications symlink.
#
# Usage: scripts/dmg.sh APP_NAME VERSION BUILD_DIR
# Output: $BUILD_DIR/Container-Desktop-<version>-arm64.dmg
#
# Env: SIGN_IDENTITY — when set to a real identity (not "-"), the DMG itself is signed too.
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 APP_NAME VERSION BUILD_DIR" >&2
    exit 64
fi
APP_NAME="$1"
VERSION="$2"
BUILD_DIR="$3"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$BUILD_DIR/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "error: $APP not found — run 'make app' first" >&2; exit 1; }

DMG="$BUILD_DIR/${APP_NAME// /-}-$VERSION-arm64.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> staging"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create $DMG"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" \
    > /dev/null

if [[ -n "${SIGN_IDENTITY:-}" && "${SIGN_IDENTITY}" != "-" ]]; then
    echo "==> codesign DMG ($SIGN_IDENTITY)"
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi

echo "==> hdiutil verify"
hdiutil verify "$DMG"
echo "==> built $DMG"
echo "$DMG"
