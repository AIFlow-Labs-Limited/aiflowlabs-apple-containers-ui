#!/usr/bin/env bash
# Cut a release locally: bump the Makefile default VERSION, promote CHANGELOG [Unreleased], commit, tag vX.Y.Z.
# Does NOT push — run `git push origin main vX.Y.Z`, then `scripts/publish-release.sh vX.Y.Z` builds + publishes the DMG locally.
# Refuses unless: clean tree, on main, in sync with origin/main, tag absent locally and on origin, `make check` green.
#
# Usage: scripts/release.sh X.Y.Z
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$ ]]; then
    echo "usage: $0 X.Y.Z   (got '${VERSION}')" >&2
    exit 64
fi
TAG="v$VERSION"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }

[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit or stash first"

BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
[[ "$BRANCH" == "main" ]] || die "releases are cut from main (on '${BRANCH:-detached HEAD}')"

echo "==> git fetch origin --tags"
git fetch --quiet --tags origin main
LOCAL="$(git rev-parse HEAD)"
REMOTE="$(git rev-parse origin/main)"
[[ "$LOCAL" == "$REMOTE" ]] || die "main ($LOCAL) is not in sync with origin/main ($REMOTE); pull or push first"

git rev-parse -q --verify "refs/tags/$TAG" > /dev/null && die "tag $TAG already exists locally"
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" > /dev/null 2>&1; then
    die "tag $TAG already exists on origin"
fi
grep -q '^## \[Unreleased\]' CHANGELOG.md || die "CHANGELOG.md has no '## [Unreleased]' heading"

echo "==> make check"
make check

TODAY="$(date +%Y-%m-%d)"

# Makefile: VERSION ?= x.y.z
sed -i '' -E "s/^(VERSION[[:space:]]+\?=[[:space:]]*).*/\1$VERSION/" Makefile

# CHANGELOG: keep an empty [Unreleased] on top, move its content under the new version heading.
awk -v v="$VERSION" -v d="$TODAY" '
    /^## \[Unreleased\]/ && !done { print; print ""; print "## [" v "] - " d; done = 1; next }
    { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

# sed/awk silently no-op when a pattern stops matching; verify both edits landed.
grep -qE "^VERSION[[:space:]]+\?=[[:space:]]*${VERSION//./\\.}\$" Makefile || die "Makefile VERSION was not bumped to $VERSION"
grep -qF "## [$VERSION] - $TODAY" CHANGELOG.md || die "CHANGELOG.md has no '## [$VERSION] - $TODAY' heading"
[[ -n "$(git status --porcelain Makefile CHANGELOG.md)" ]] || die "nothing changed in Makefile/CHANGELOG.md"

git add Makefile CHANGELOG.md
git commit -m "release: $TAG"
git tag -a "$TAG" -m "Container Desktop $VERSION"
echo "==> tagged $TAG (not pushed). Publish with: git push origin main $TAG"
