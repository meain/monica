#!/usr/bin/env bash
# Render the monica GUI to a PNG for visual inspection, optionally after
# selecting a different row via Down-arrow (the first row's preview can show
# the very session driving this test — see SKILL.md). Prints the PNG path on
# success.
#
# Usage: shot.sh <popover|menubar> [out.png] [down-count]
#   shot.sh popover                 -> render popover, first row selected
#   shot.sh popover /tmp/p.png 2    -> press Down twice before rendering
#   shot.sh menubar
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
MODE="${1:?usage: shot.sh <popover|menubar> [out.png] [down-count]}"
OUT="${2:-/tmp/monica-${MODE}-shot.png}"
DOWN_COUNT="${3:-0}"
DELAY="${MONICA_SHOT_DELAY:-1.5}"

cd "$ROOT"
# Bare `swift build` needs the system CLT SDK, not the nix devshell's SDKROOT
# (see AGENTS.md's SDKROOT gotcha).
env -u SDKROOT -u DEVELOPER_DIR swift build >/dev/null 2>&1

rm -f "$OUT"

case "$MODE" in
popover)
    MONICA_SHOT="$OUT" MONICA_SHOT_DELAY="$DELAY" ./.build/debug/monica >/dev/null 2>&1 &
    PID=$!
    if [ "$DOWN_COUNT" -gt 0 ]; then
        sleep 1.2
        for _ in $(seq 1 "$DOWN_COUNT"); do
            osascript -e 'tell application "System Events" to key code 125' >/dev/null 2>&1 || true
        done
    fi
    ;;
menubar)
    MONICA_SHOT_MENUBAR="$OUT" ./.build/debug/monica >/dev/null 2>&1 &
    PID=$!
    ;;
*)
    echo "ERROR: unknown mode '$MODE' (want popover|menubar)" >&2
    exit 1
    ;;
esac

# Poll for the render (the app writes the PNG then self-terminates). This
# avoids a cold-start race where a fixed sleep+kill can kill the app before it
# has rendered.
deadline=$((SECONDS + ${DELAY%.*} + 8))
while [ ! -s "$OUT" ] && [ "$SECONDS" -lt "$deadline" ] && kill -0 "$PID" 2>/dev/null; do
    sleep 0.3
done
kill "$PID" >/dev/null 2>&1 || true

if [ -s "$OUT" ]; then
    echo "$OUT"
else
    echo "ERROR: no PNG produced at $OUT" >&2
    exit 1
fi
