#!/bin/bash
# Reproduces docs/screenshots/*.png against the mock backend.
#
#   make app CONFIG=debug && docs/launch/capture/capture.sh [dark|light|both] [name ...]
#
# Needs: an unlocked screen at least 1680×960 points, Screen Recording + Accessibility permission for the terminal,
# a DEBUG build (the CONTAINER_DESKTOP_DEBUG_OPEN tokens are DEBUG-only). Each shot launches the app fresh with the
# tokens from shots.txt (name|tokens|seconds|window-title|extra args), keeps it frontmost (pollers pause while the
# app is inactive), runs pre-<name>.sh if present, and captures the window without its shadow.
#
# Personal data: the app runs with CFFIXED_USER_HOME=$DEMO_HOME (default /Users/Shared/you) so home-relative paths
# and the build history never show the real user; MockBackend scrubs fixture paths to /Users/you.
# The Terminal shot execs into a REAL container named `db` (the mock's terminal command is the real CLI):
#   container run -d --name db -e POSTGRES_PASSWORD=demo -e POSTGRES_USER=acdemo -e POSTGRES_DB=acdemo \
#     docker.io/library/postgres:16-alpine          # and `container rm -f db` afterwards
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HERE="$ROOT/docs/launch/capture"
APP="$ROOT/build/Container Desktop.app/Contents/MacOS/ContainerDesktop"
OUT="${OUT:-$ROOT/docs/screenshots}"
TMP="${TMPDIR:-/tmp}/cd-capture"
export DEMO_HOME="${DEMO_HOME:-/Users/Shared/you}"
mkdir -p "$TMP" "$OUT" "$DEMO_HOME/src/acdemo"
[ -x "$TMP/winlist" ] || swiftc -O "$HERE/winlist.swift" -o "$TMP/winlist"
[ -x "$TMP/click" ] || swiftc -O "$HERE/click.swift" -o "$TMP/click"
export CLICK="$TMP/click"
[ -f "$DEMO_HOME/src/acdemo/Dockerfile" ] || printf 'FROM docker.io/library/python:3.11-slim\nCOPY app.py /app.py\n' \
    >"$DEMO_HOME/src/acdemo/Dockerfile"

ax() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1) to $2" >/dev/null 2>&1; }

launch() {  # launch <appearance> <tokens> [args…] → pid
    local ap=$1 tok=$2; shift 2
    python3 "$HERE/seed-builds.py"
    CFFIXED_USER_HOME="$DEMO_HOME" CONTAINER_DESKTOP_BACKEND=mock CONTAINER_DESKTOP_DEBUG_OPEN="$tok" \
        "$APP" -appearance "$ap" -ApplePersistenceIgnoreState YES "$@" >"$TMP/app.log" 2>&1 &
    local pid=$!
    disown
    for _ in $(seq 1 30); do sleep 0.3; ax $pid "count windows" && break; done
    ax $pid "set frontmost to true"
    ax $pid 'set position of (first window whose name is not "Activity") to {240, 60}'
    ax $pid 'set size of (first window whose name is not "Activity") to {1440, 900}'
    echo $pid
}

hold() { local end=$((SECONDS + $2)); while [ $SECONDS -lt $end ]; do ax $1 "set frontmost to true"; sleep 1.5; done; }

capture() {  # capture <pid> <file> [title-match]: largest on-screen layer-0 window of pid
    local id
    id=$("$TMP/winlist" "$1" | grep ' layer 0 onscreen 1 ' | { if [ -n "${3:-}" ]; then grep -- "$3"; else cat; fi; } |
        awk '{print $1, $8*$9}' | sort -k2 -n -r | head -1 | cut -d' ' -f1)
    screencapture -x -o -l "$id" "$2"
}

shoot() {  # shoot <appearance> <name>
    local line tok wait match extra pid
    line=$(grep "^$2|" "$HERE/shots.txt") || { echo "unknown shot $2" >&2; return 1; }
    IFS='|' read -r _ tok wait match extra <<<"$line"
    # shellcheck disable=SC2086
    pid=$(launch "$1" "$tok" $extra)
    hold "$pid" "$wait"
    [ -f "$HERE/pre-$2.sh" ] && bash "$HERE/pre-$2.sh" "$pid"
    capture "$pid" "$OUT/$2-$1.png" "$match"
    echo "$2-$1.png"
    kill "$pid"; sleep 1
}

modes=${1:-both}; shift || true
[ "$modes" = both ] && modes="dark light"
names=("$@")
[ ${#names[@]} -eq 0 ] && names=($(cut -d'|' -f1 "$HERE/shots.txt" | grep -v '^#') engine-stopped menubar)
for ap in $modes; do
    for n in "${names[@]}"; do
        case $n in
        engine-stopped)  # the mock's label would read "Mock (fixtures…)"; show what a real install shows
            pid=$(CONTAINER_DESKTOP_MOCK_DESCRIPTION="CLI (/usr/local/bin/container)" \
                CONTAINER_DESKTOP_ALLOW_REAL_ENGINE_TESTS=1 launch "$ap" stopped)
            hold "$pid" 5; capture "$pid" "$OUT/$n-$ap.png"; echo "$n-$ap.png"; kill "$pid"; sleep 1 ;;
        menubar)  # the menu bar extra's menu window only (no other menu bar items)
            pid=$(launch "$ap" "section=containers"); hold "$pid" 5
            ax "$pid" "click menu bar item 1 of menu bar 2" &
            sleep 1.5
            id=$("$TMP/winlist" "$pid" | awk '$3 == 101 {print $1}' | head -1)
            screencapture -x -o -l "$id" "$OUT/$n-$ap.png"; echo "$n-$ap.png"
            osascript -e 'tell application "System Events" to key code 53'; kill "$pid"; sleep 1 ;;
        *) shoot "$ap" "$n" ;;
        esac
    done
done
