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
# Claude Code's own session registry — monica's status source for claude.
# Read-only: claude removes its file itself when the demo session is killed.
STATUS_DIR="$HOME/.claude/sessions"
MEDIA_ISSUE=4 # meain/monica#4 "Media" — tracking issue for images referenced from README/docs

CLAUDE_PID=""
STATUS_FILE=""

cleanup() {
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$DEMO_DIR"
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

# 3. Find the claude pid under this pane — its session file is how we tell
# whether the prompt actually got submitted and when the turn is done.
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

STATUS_FILE="$STATUS_DIR/$CLAUDE_PID.json"

# 4. Drive one short, clean prompt that produces a nicely structured reply
# (heading + bullets) — good screenshot content, no real work content.
PROMPT='Add an Add(a, b int) int function and a Multiply(a, b int) int function to main.go, each with a one-line doc comment. Then reply with a short summary: one heading, then a few bullet points describing what you added and why, in plain prose (no code block in the reply itself).'
tmux send-keys -t "$SESSION:$WINDOW" "$PROMPT" Enter
# Enter that lands too soon after the pasted text is ignored, leaving the
# prompt unsent — one retry 3s later wasn't always enough (seen needing
# ~11s). Keep re-sending Enter until the session file flips to busy.
# Don't detect "unsent" from capture-pane text instead: tmux wraps long
# lines at the pane width, so a search for the whole prompt never matches.
deadline=$((SECONDS + 40))
until grep -q '"status": *"busy"' "$STATUS_FILE" 2>/dev/null; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "ERROR: prompt never submitted in $SESSION:$WINDOW" >&2
    exit 1
  fi
  sleep 3
  tmux send-keys -t "$SESSION:$WINDOW" Enter
done

# 5. Wait for the turn to finish.
deadline=$((SECONDS + 90))
while [ "$SECONDS" -lt "$deadline" ]; do
  if [ -f "$STATUS_FILE" ] && grep -q '"status": *"idle"' "$STATUS_FILE" 2>/dev/null; then
    break
  fi
  sleep 2
done
if [ ! -f "$STATUS_FILE" ]; then
  echo "ERROR: no Claude Code session file appeared at $STATUS_FILE" >&2
  exit 1
fi

# 6. Render the popover, filtered down to the demo agent by typing its
# project name into the search field — robust regardless of how many real
# agents are running, no row-counting needed.
cd "$ROOT"
# Through the devshell: a plain-CLT build fails since Swift 6.4 (AGENTS.md).
nix develop -c make build >/dev/null 2>&1

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

# 7. Upload the render via `gh image` (produces a github.com/user-attachments
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
# README embeds it as `<img ... src="URL" alt="Monica popover">`.
PATTERN="s#(<img [^>]*src=\")[^\"]+(\"[^>]*alt=\"Monica popover\")#\1$URL\2#"
if sed --version >/dev/null 2>&1; then
  sed -i -E "$PATTERN" "$ROOT/README.md"
else
  sed -i '' -E "$PATTERN" "$ROOT/README.md"
fi
grep -q "$URL" "$ROOT/README.md" || {
  echo "ERROR: uploaded $URL but found no Monica popover <img> in README.md to update" >&2
  exit 1
}

echo "$URL"
