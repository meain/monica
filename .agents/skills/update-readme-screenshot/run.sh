#!/usr/bin/env bash
# Refresh the README popover screenshot by running a real Claude Code session
# against a disposable demo project, rendering monica's popover (via the
# screenshot-test skill's MONICA_SHOT hook) with that session selected and
# nothing else, then uploading the PNG via `gh image` (no binaries committed
# to the repo — see the meain/monica#4 "Media" issue) and patching README.md
# to point at the new URL. See SKILL.md for the full rationale.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
DEMO_DIR="/tmp/demo-app"
SESSION="monica-demo"
WINDOW="demo"
STATUS_DIR="$HOME/.local/share/aistatus"
MEDIA_ISSUE=4 # meain/monica#4 "Media" — tracking issue for images referenced from README/docs

CLAUDE_PID=""
STATUS_FILE=""

cleanup() {
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$DEMO_DIR"
  [ -n "$STATUS_FILE" ] && rm -f "$STATUS_FILE"
}
trap cleanup EXIT

pane_text() {
  tmux capture-pane -t "$SESSION:$WINDOW" -p 2>/dev/null || true
}

wait_for_pane() {
  local pattern="$1" timeout="$2"
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if pane_text | grep -qi "$pattern"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# 1. Set up a small, disposable demo project.
rm -rf "$DEMO_DIR"
mkdir -p "$DEMO_DIR"
cat >"$DEMO_DIR/README.md" <<'EOF'
# demo-app

A small demo service used to test the monica menu bar app.
EOF
cat >"$DEMO_DIR/main.go" <<'EOF'
package main

func main() {}
EOF

# 2. Start a real Claude Code session in it, in a brand-new tmux session so it
# never touches any of your real work sessions.
tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
tmux new-session -d -s "$SESSION" -n "$WINDOW" -c "$DEMO_DIR"
tmux send-keys -t "$SESSION:$WINDOW" 'claude' Enter

if wait_for_pane 'trust this folder' 20; then
  tmux send-keys -t "$SESSION:$WINDOW" Enter
fi
wait_for_pane 'Try ' 20 || {
  echo "ERROR: claude never reached its ready prompt in $SESSION:$WINDOW" >&2
  exit 1
}

# 3. Drive one short, clean prompt that produces a nicely structured reply
# (heading + bullets) — good screenshot content, no real work content.
PROMPT='Add an Add(a, b int) int function and a Multiply(a, b int) int function to main.go, each with a one-line doc comment. Then reply with a short summary: one heading, then a few bullet points describing what you added and why, in plain prose (no code block in the reply itself).'
tmux send-keys -t "$SESSION:$WINDOW" "$PROMPT" Enter
sleep 3
# The first Enter reliably lands before the textarea commits the pasted
# text (observed every time during manual testing), leaving the prompt
# sitting unsent — a second Enter is needed unconditionally. Detecting
# "still unsent" from capture-pane text is NOT reliable here: tmux wraps
# long lines at the pane width, so a fixed-string search for the whole
# one-line prompt never matches regardless of send state — don't
# reintroduce that check.
tmux send-keys -t "$SESSION:$WINDOW" Enter

# 4. Find the claude pid under this pane, then wait for its aistatus file to
# go idle.
PANE_PID="$(tmux list-panes -t "$SESSION:$WINDOW" -F '#{pane_pid}')"
deadline=$((SECONDS + 15))
while [ "$SECONDS" -lt "$deadline" ]; do
  CLAUDE_PID="$(pgrep -P "$PANE_PID" claude 2>/dev/null | head -1 || true)"
  [ -n "$CLAUDE_PID" ] && break
  sleep 1
done
if [ -z "$CLAUDE_PID" ]; then
  echo "ERROR: could not find claude pid under pane $PANE_PID" >&2
  exit 1
fi

STATUS_FILE="$STATUS_DIR/pid-$CLAUDE_PID.json"
deadline=$((SECONDS + 90))
while [ "$SECONDS" -lt "$deadline" ]; do
  if [ -f "$STATUS_FILE" ] && grep -q '"status": *"idle"' "$STATUS_FILE" 2>/dev/null; then
    break
  fi
  sleep 2
done
if [ ! -f "$STATUS_FILE" ]; then
  echo "ERROR: no aistatus file appeared at $STATUS_FILE — hook not installed?" >&2
  exit 1
fi

# 5. Render the popover, filtered down to the demo agent by typing its
# project name into the search field — robust regardless of how many real
# agents are running, no row-counting needed.
cd "$ROOT"
env -u SDKROOT -u DEVELOPER_DIR swift build >/dev/null 2>&1

TMP_SHOT="/tmp/monica-readme-shot.png"
rm -f "$TMP_SHOT"
MONICA_SHOT="$TMP_SHOT" MONICA_SHOT_DELAY=2.5 ./.build/debug/monica >/dev/null 2>&1 &
SHOT_PID=$!
sleep 1.2
osascript -e 'tell application "System Events" to keystroke "demo-app"' >/dev/null 2>&1 || true

deadline=$((SECONDS + 15))
while [ ! -s "$TMP_SHOT" ] && [ "$SECONDS" -lt "$deadline" ] && kill -0 "$SHOT_PID" 2>/dev/null; do
  sleep 0.3
done
kill "$SHOT_PID" >/dev/null 2>&1 || true

if [ ! -s "$TMP_SHOT" ]; then
  echo "ERROR: no PNG produced at $TMP_SHOT" >&2
  exit 1
fi

# 6. Upload the render via `gh image` (produces a github.com/user-attachments
# URL — no PNG committed to the repo), post it to the Media tracking issue
# for a durable record, then patch README.md's screenshot line to point at
# the new URL. (Cleanup of the tmux session, demo dir, and aistatus file
# happens in the EXIT trap.)
EMBED="$(gh image "$TMP_SHOT" --repo meain/monica)"
URL="$(echo "$EMBED" | grep -oE 'https://github.com/user-attachments/assets/[a-f0-9-]+')"
rm -f "$TMP_SHOT"

gh issue comment "$MEDIA_ISSUE" --repo meain/monica --body "### README popover screenshot refresh

$EMBED" >/dev/null

# macOS ships BSD sed (`-i ''`), but this machine's `sed` resolves to the nix
# gnused package instead (GNU sed, `-i` takes no separate suffix arg) —
# `sed -i '' -E ...` under GNU sed misparses `''` as the script itself and the
# real script as a file to read, failing with "No such file or directory".
# Detect which flavor is on PATH rather than hardcoding one syntax.
if sed --version >/dev/null 2>&1; then
  sed -i -E "s#!\[Monica popover\]\([^)]+\)#![Monica popover]($URL)#" "$ROOT/README.md"
else
  sed -i '' -E "s#!\[Monica popover\]\([^)]+\)#![Monica popover]($URL)#" "$ROOT/README.md"
fi

echo "$URL"
