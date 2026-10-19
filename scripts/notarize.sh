#!/usr/bin/env bash
# Notarize and staple a DMG (or zipped .app) with Apple's notary service.
#
# Usage: scripts/notarize.sh PATH_TO_DMG
#
# Requires:
#   - The artifact signed with a "Developer ID Application" identity (make app dmg SIGN_IDENTITY="Developer ID …").
#   - NOTARY_PROFILE: a keychain profile created ONCE per machine with
#       xcrun notarytool store-credentials container-desktop-notary \
#           --apple-id "<apple-id-email>" --team-id "<TEAMID>" --password "<app-specific-password>"
#     (app-specific password from appleid.apple.com → Sign-In and Security → App-Specific Passwords),
#     then export NOTARY_PROFILE=container-desktop-notary.
#
# With NOTARY_PROFILE unset this script prints what is missing and exits 0, so `make notarize` is safe in dev.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 PATH_TO_DMG" >&2
    exit 64
fi
TARGET="$1"

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    cat <<'MSG'
notarize: NOTARY_PROFILE is not set — skipping notarization (nothing was submitted).
  One-time setup:
    xcrun notarytool store-credentials container-desktop-notary \
        --apple-id "<apple-id>" --team-id "<TEAMID>" --password "<app-specific-password>"
    export NOTARY_PROFILE=container-desktop-notary
  Then: make app dmg notarize SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
MSG
    exit 0
fi

[[ -f "$TARGET" ]] || { echo "error: $TARGET not found — run 'make dmg' first" >&2; exit 1; }

# Capture first: `codesign -dv | grep -q` under pipefail misreads both an unsigned file and grep's early exit.
if ! SIGNATURE="$(codesign -dv --verbose=2 "$TARGET" 2>&1)"; then
    echo "error: $TARGET is not signed; run 'make app dmg' with SIGN_IDENTITY=\"Developer ID Application: …\"" >&2
    echo "$SIGNATURE" >&2
    exit 1
fi
if grep -q "Signature=adhoc" <<< "$SIGNATURE"; then
    echo "error: $TARGET is ad-hoc signed; notarization needs a Developer ID signature" >&2
    exit 1
fi
if ! grep -q "^Authority=Developer ID Application" <<< "$SIGNATURE"; then
    echo "error: $TARGET is not signed with a Developer ID Application identity:" >&2
    grep "^Authority=" <<< "$SIGNATURE" >&2 || true
    exit 1
fi

echo "==> notarytool submit $TARGET (profile: $NOTARY_PROFILE)"
xcrun notarytool submit "$TARGET" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> stapler staple"
xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
spctl --assess --type open --context context:primary-signature --verbose "$TARGET" || true
echo "==> notarized $TARGET"
