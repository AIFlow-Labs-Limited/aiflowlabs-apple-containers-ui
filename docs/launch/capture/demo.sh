#!/bin/bash
# Records docs/launch/demo.mp4 + demo.gif against the mock backend:
#   Images → Pull sheet (redis:7) → Activity streams it → Containers → ⌘N Run sheet → container appears → Logs → Terminal
#
#   make app CONFIG=debug && docs/launch/capture/demo.sh
#
# Needs an unlocked screen ≥ 1680×960 pt, Screen Recording + Accessibility for the terminal, ffmpeg and gifski
# (brew install ffmpeg gifski). The Terminal step execs into a REAL container named `redis`:
#   container run -d --name redis docker.io/library/redis:7-alpine      # `container rm -f redis` afterwards
# Clicks use window-relative points for the 1440×900 window at {240, 60}; adjust W() if the layout changes.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
HERE="$ROOT/docs/launch/capture"
APP="$ROOT/build/Container Desktop.app/Contents/MacOS/ContainerDesktop"
TMP="${TMPDIR:-/tmp}/cd-demo"
export DEMO_HOME="${DEMO_HOME:-/Users/Shared/you}"
mkdir -p "$TMP"
[ -x "$TMP/click" ] || swiftc -O "$HERE/click.swift" -o "$TMP/click"
W() { "$TMP/click" $((240 + $1)) $((60 + $2)); }   # click at window point
key() { osascript -e "tell application \"System Events\" to $1"; }
type() { key "keystroke \"$1\""; }
ax() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to $1" >/dev/null 2>&1; }

python3 "$HERE/seed-builds.py"
CFFIXED_USER_HOME="$DEMO_HOME" CONTAINER_DESKTOP_BACKEND=mock CONTAINER_DESKTOP_DEBUG_OPEN="section=images" \
    "$APP" -appearance dark -ApplePersistenceIgnoreState YES >"$TMP/app.log" 2>&1 &
PID=$!
disown
sleep 3
ax "set frontmost to true"
ax 'set position of window 1 to {240, 60}'
ax 'set size of window 1 to {1440, 900}'
sleep 2

screencapture -x -v -V 30 -R 240,60,1440,900 "$TMP/raw.mov" &
REC=$!
sleep 1.5
W 853 25; sleep 1.2                       # Images toolbar: Pull…
type "docker.io/library/redis:7"; sleep 0.6
key "key code 36"; sleep 0.4              # Return = Pull
key 'keystroke "0" using {command down, shift down}'; sleep 0.6   # ⇧⌘0 Activity
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set position of window \"Activity\" to {530, 260}" >/dev/null 2>&1 || true
sleep 3
key 'keystroke "w" using {command down}'; sleep 0.6               # close Activity
key 'keystroke "1" using {command down}'; sleep 1                 # ⌘1 Containers
key 'keystroke "n" using {command down}'; sleep 1.2               # ⌘N Run sheet
type "docker.io/library/redis:7"; sleep 0.4
key "key code 48"; type "redis"; sleep 0.8                        # Tab → name
W 1011 806; sleep 2.5                                             # click Run; container appears
W 300 275; sleep 0.4                                              # select the new row (sorted by name)
W 557 419; sleep 3                                                # Logs tab
W 740 419; sleep 0.8                                              # Terminal tab
W 833 738; sleep 2.5; W 800 640                                   # Open shell, focus
type "redis-cli ping"; key "key code 36"; sleep 1
type "redis-cli set launch today && redis-cli get launch"; key "key code 36"; sleep 4
wait $REC || true
kill $PID || true

ffmpeg -y -loglevel error -i "$TMP/raw.mov" -vf "scale=1440:-2,fps=30" -c:v libx264 -pix_fmt yuv420p -crf 20 \
    -movflags +faststart "$ROOT/docs/launch/demo.mp4"
rm -rf "$TMP/frames"; mkdir -p "$TMP/frames"
ffmpeg -y -loglevel error -i "$TMP/raw.mov" -vf "fps=12,scale=1200:-1:flags=lanczos" "$TMP/frames/f%04d.png"
gifski --fps 12 --width 1200 --quality 80 -o "$ROOT/docs/launch/demo.gif" "$TMP"/frames/f*.png
ls -lh "$ROOT/docs/launch/demo.mp4" "$ROOT/docs/launch/demo.gif"
