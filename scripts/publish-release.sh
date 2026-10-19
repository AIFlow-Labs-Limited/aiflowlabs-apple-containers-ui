#!/usr/bin/env bash
# Build the DMG for an existing tag on this Mac and publish it as a GitHub release (no CI involved).
#
#   scripts/publish-release.sh vX.Y.Z [--draft] [--prerelease]
#
# Prerequisites: the tag exists locally and on origin (see scripts/release.sh), `gh auth status` is OK,
# and the working tree is clean. Set SIGN_IDENTITY / NOTARY_PROFILE for a signed + notarized build
# (see docs/release/RELEASING.md); without them the DMG is ad-hoc signed and the notes say so.
set -euo pipefail

TAG="${1:-}"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]] || { echo "usage: $0 vX.Y.Z [--draft] [--prerelease]" >&2; exit 64; }
shift
EXTRA=("$@")
VERSION="${TAG#v}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
die() { echo "error: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG does not exist locally (run scripts/release.sh ${VERSION})"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null || die "tag $TAG is not on origin (git push origin $TAG)"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$TAG^{commit}")" ]] || die "HEAD is not at $TAG; git checkout $TAG first"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated"

echo "==> make check"
make check

echo "==> make dmg VERSION=$VERSION"
make dmg VERSION="$VERSION"
DMG="build/Container-Desktop-${VERSION}-arm64.dmg"
[[ -f "$DMG" ]] || die "expected $DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> notarize"
    scripts/notarize.sh "$DMG"
fi

(cd build && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" && cat "$(basename "$DMG").sha256")

NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
{
    if [[ -z "${NOTARY_PROFILE:-}" ]]; then
        cat <<'EOF'
> **This build is not notarized yet** (ad-hoc signed until a Developer ID is configured).
> On first launch macOS blocks it. Either open **System Settings → Privacy & Security**, scroll to the
> message about Container Desktop and click **Open Anyway**, or run once in Terminal:
> `xattr -dr com.apple.quarantine "/Applications/Container Desktop.app"`

EOF
    fi
    echo "Verify the download: \`shasum -a 256 -c $(basename "$DMG").sha256\`"
    echo
    # Changelog section for this version, if present.
    awk -v v="$VERSION" '
        $0 ~ "^## \\[" v "\\]" { on = 1; next }
        on && /^## \[/ { exit }
        on { print }
    ' CHANGELOG.md
} > "$NOTES"

PRE=()
[[ "$TAG" == *-* ]] && PRE=(--prerelease)

echo "==> gh release create $TAG"
gh release create "$TAG" "$DMG" "$DMG.sha256" \
    --title "Container Desktop $TAG" \
    --notes-file "$NOTES" \
    --generate-notes \
    "${PRE[@]}" "${EXTRA[@]}"
echo "published: $(gh release view "$TAG" --json url -q .url)"
