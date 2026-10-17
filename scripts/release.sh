#!/usr/bin/env bash
# Cut a release locally: bump the Makefile default VERSION, promote CHANGELOG [Unreleased], commit, tag vX.Y.Z.
# Does NOT push — run `git push origin main vX.Y.Z` yourself; the tag triggers .github/workflows/release.yml.
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

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty; commit or stash first" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" > /dev/null; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi
grep -q '^## \[Unreleased\]' CHANGELOG.md || { echo "error: CHANGELOG.md has no '## [Unreleased]' heading" >&2; exit 1; }

TODAY="$(date +%Y-%m-%d)"

# Makefile: VERSION ?= x.y.z
sed -i '' -E "s/^(VERSION[[:space:]]+\?=[[:space:]]*).*/\1$VERSION/" Makefile

# CHANGELOG: keep an empty [Unreleased] on top, move its content under the new version heading.
awk -v v="$VERSION" -v d="$TODAY" '
    /^## \[Unreleased\]/ && !done { print; print ""; print "## [" v "] - " d; done = 1; next }
    { print }
' CHANGELOG.md > CHANGELOG.md.tmp && mv CHANGELOG.md.tmp CHANGELOG.md

git add Makefile CHANGELOG.md
git commit -m "release: $TAG"
git tag -a "$TAG" -m "Container Desktop $VERSION"
echo "==> tagged $TAG (not pushed). Publish with: git push origin HEAD $TAG"
