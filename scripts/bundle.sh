#!/usr/bin/env bash
# Assemble and sign the Container Desktop .app bundle from a SwiftPM build.
#
# Usage: scripts/bundle.sh APP_NAME BUNDLE_ID VERSION CONFIG BUILD_DIR
#   e.g. scripts/bundle.sh "Container Desktop" io.aiflowlabs.containerdesktop 0.1.0 release build
#
# Env:
#   SIGN_IDENTITY  codesign identity (default "-" = ad-hoc). Use "Developer ID Application: …" for releases.
#
# Idempotent: the bundle is rebuilt from scratch on every run.
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "usage: $0 APP_NAME BUNDLE_ID VERSION CONFIG BUILD_DIR" >&2
    exit 64
fi

APP_NAME="$1"
BUNDLE_ID="$2"
VERSION="$3"
CONFIG="$4"
BUILD_DIR="$5"
PRODUCT="ContainerDesktop"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

TEMPLATE="Resources/Info.plist.template"
ENTITLEMENTS="Resources/ContainerDesktop.entitlements"
ICON="Resources/AppIcon.icns"
for f in "$TEMPLATE" "$ENTITLEMENTS" "$ICON"; do
    [[ -f "$f" ]] || { echo "error: missing $f" >&2; exit 1; }
done

echo "==> swift build -c $CONFIG --product $PRODUCT"
swift build -c "$CONFIG" --product "$PRODUCT"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
[[ -x "$BIN_DIR/$PRODUCT" ]] || { echo "error: $BIN_DIR/$PRODUCT not found" >&2; exit 1; }

# CFBundleVersion = monotonically increasing commit count (falls back to 1 outside a git checkout).
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

mkdir -p "$BUILD_DIR"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_DIR/$PRODUCT" "$CONTENTS/MacOS/$PRODUCT"
cp "$ICON" "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Render Info.plist. Values are escaped for sed's replacement side and for XML.
xml_escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
sed_escape() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }
render() { sed_escape "$(xml_escape "$1")"; }
sed \
    -e "s|@EXECUTABLE@|$(render "$PRODUCT")|g" \
    -e "s|@APP_NAME@|$(render "$APP_NAME")|g" \
    -e "s|@BUNDLE_ID@|$(render "$BUNDLE_ID")|g" \
    -e "s|@VERSION@|$(render "$VERSION")|g" \
    -e "s|@BUILD_NUMBER@|$(render "$BUILD_NUMBER")|g" \
    "$TEMPLATE" > "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" > /dev/null

# SwiftPM resource bundles (Bundle.module looks in Bundle.main.resourceURL for app bundles).
shopt -s nullglob
bundles=("$BIN_DIR"/*.bundle)
shopt -u nullglob
for b in "${bundles[@]}"; do
    echo "    + $(basename "$b")"
    cp -R "$b" "$CONTENTS/Resources/"
done

echo "==> codesign (identity: $SIGN_IDENTITY)"
codesign_args=(--force --deep --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign_args+=(--timestamp)
fi
codesign "${codesign_args[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "==> built $ROOT/$APP ($VERSION build $BUILD_NUMBER)"
echo "$APP"
