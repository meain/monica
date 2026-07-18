# Setup

Monica doesn't talk to Claude Code or `pi` directly — it discovers live processes
from the tmux pane tree, then reads status from JSON files under
`~/.local/share/aistatus/pid-<pid>.json`. Those files are written by a Claude Code
hook and a `pi` extension, both listed below. Without one of these in place, an
agent will show up in the list (Monica can see the tmux pane and process) but
without a status glyph, and without a "last message" preview.

Monica only reads this directory — it never writes to it, so nothing here breaks if
you edit the hook/extension yourselves.

## Claude Code

Add an `update-status.sh` hook script, then wire it into `~/.claude/settings.json`.

`~/.claude/hooks/update-status.sh`:

```bash
#!/usr/bin/env bash
# Update Claude session status for tmux window status display.
# Writes to ~/.local/share/aistatus/pid-<pid>.json

INPUT=$(cat)

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
[ -z "$SESSION_ID" ] && exit 0

[ -z "${TMUX_PANE:-}" ] && exit 0

# This hook runs as a child of the claude process itself, but walk up a few
# levels just in case an intermediate shell/wrapper is in between.
find_claude_pid() {
  p="$PPID"
  for _ in 1 2 3 4 5; do
    [ -z "$p" ] && break
    base=$(basename "$(ps -o comm= -p "$p" 2>/dev/null)" 2>/dev/null)
    if [ "$base" = "claude" ]; then
      echo "$p"
      return
    fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -z "$p" ] || [ "$p" = "1" ] && break
  done
  echo "$PPID"
}
PID=$(find_claude_pid)
[ -z "$PID" ] && exit 0

HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
PROJECT=$(basename "$CWD")

case "$HOOK_EVENT" in
  Stop)         STATUS="idle" ;;
  Notification) STATUS="waiting" ;;
  *)            STATUS="working" ;;
esac

STATUS_DIR="$HOME/.local/share/aistatus"
mkdir -p "$STATUS_DIR"

TMP=$(mktemp "$STATUS_DIR/.tmp.XXXXXX")
jq -n \
  --arg session_id "$SESSION_ID" \
  --argjson pid "$PID" \
  --arg status "$STATUS" \
  --arg hook_event "$HOOK_EVENT" \
  --arg project "$PROJECT" \
  --argjson timestamp "$(date +%s)" \
  '{session_id: $session_id, pid: $pid, status: $status, hook_event: $hook_event, project: $project, timestamp: $timestamp}' \
  > "$TMP" && mv "$TMP" "$STATUS_DIR/pid-${PID}.json"
```

Make it executable: `chmod +x ~/.claude/hooks/update-status.sh`.

Then register it for the `Stop`, `Notification`, `UserPromptSubmit`, and
`PostToolUse` hooks in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/update-status.sh || exit 0" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/update-status.sh || exit 0" }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/update-status.sh || exit 0", "async": true }] }
    ],
    "PostToolUse": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/update-status.sh || exit 0", "async": true }] }
    ]
  }
}
```

`Stop` maps to `idle`, `Notification` maps to `waiting` (Claude is blocked on you),
everything else maps to `working`.

Monica's "last message" preview for Claude Code reads
`~/.claude/projects/<cwd, every non-alphanumeric char -> '-'>/<sessionId>.jsonl`
directly — no extra setup needed there, that file already exists as part of
Claude Code's own session storage.

### Clearing stale status on `/clear`

`/clear` starts a fresh session in the same pane/pid without a new `Stop` or
`Notification` event, so the pid's status file can otherwise keep showing the
previous session's stale glyph. Add a second hook script,
`~/.claude/hooks/clear-status.sh`, that just removes the pid's status file:

```bash
#!/usr/bin/env bash
# Remove the pid-keyed status file on /clear so stale status doesn't linger.
# Triggered by SessionStart (matcher "clear").

INPUT=$(cat)

[ -z "${TMUX_PANE:-}" ] && exit 0

# This hook runs as a child of the claude process itself, but walk up a few
# levels just in case an intermediate shell/wrapper is in between.
find_claude_pid() {
  p="$PPID"
  for _ in 1 2 3 4 5; do
    [ -z "$p" ] && break
    base=$(basename "$(ps -o comm= -p "$p" 2>/dev/null)" 2>/dev/null)
    if [ "$base" = "claude" ]; then
      echo "$p"
      return
    fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -z "$p" ] || [ "$p" = "1" ] && break
  done
  echo "$PPID"
}
PID=$(find_claude_pid)
[ -z "$PID" ] && exit 0

rm -f "$HOME/.local/share/aistatus/pid-${PID}.json"
```

Make it executable (`chmod +x ~/.claude/hooks/clear-status.sh`) and register it
for `SessionStart` with the `clear` matcher, so it only fires on `/clear` and
not on every new session:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "clear",
        "hooks": [{ "type": "command", "command": "~/.claude/hooks/clear-status.sh || exit 0" }]
      }
    ]
  }
}
```

Without this, an agent that runs `/clear` keeps showing its old status glyph
(and stale "last message" preview) until the next `Stop`/`Notification` event
overwrites the file — this hook deletes it immediately instead, so Monica falls
back to showing the agent with no status glyph until the new session emits its
first real event.

## pi

Drop an extension file into `~/.pi/agent/extensions/`, e.g.
`~/.pi/agent/extensions/tmux-status.ts`:

```typescript
/**
 * Tmux Status Extension
 *
 * Updates ~/.local/share/aistatus/pid-<pid>.json on agent lifecycle events.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { writeFile, mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export default function (pi: ExtensionAPI) {
  const STATUS_DIR = join(homedir(), ".local/share/aistatus");

  async function writeStatus(
    status: "working" | "idle",
    sessionId: string,
    project: string,
    event: string
  ): Promise<void> {
    if (!process.env.TMUX_PANE) return;
    await mkdir(STATUS_DIR, { recursive: true });
    const pid = process.pid;
    const payload = JSON.stringify({
      session_id: sessionId,
      pid,
      status,
      hook_event: event,
      project,
      timestamp: Math.floor(Date.now() / 1000),
    });
    const tmp = join(STATUS_DIR, `.tmp.${pid}`);
    await writeFile(tmp, payload);
    await pi.exec("mv", [tmp, join(STATUS_DIR, `pid-${pid}.json`)]);
  }

  pi.on("agent_start", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId?.() ?? "";
    const project = ctx.cwd.split("/").pop() ?? "";
    await writeStatus("working", sessionId, project, "agent_start");
  });

  pi.on("agent_end", async (_event, ctx) => {
    const sessionId = ctx.sessionManager.getSessionId?.() ?? "";
    const project = ctx.cwd.split("/").pop() ?? "";
    await writeStatus("idle", sessionId, project, "agent_end");
  });
}
```

pi loads any `.ts` file under `~/.pi/agent/extensions/` automatically, no
registration step needed beyond placing the file there. Unlike Claude Code, pi has
no separate "waiting on you" state — `agent_start` maps to `working`, `agent_end`
maps to `idle`.

Monica's "last message" preview for `pi` reads session files under
`~/.pi/agent/sessions/<"-" + cwd.replacingOccurrences(of: "/", with: "-") + "--">/`
— either a flat `<timestamp>_<sessionId>.jsonl` file, or (for resumed/branched
sessions) a `<timestamp>_<sessionId>` directory with nested `<hash>/run-N/session.jsonl`
files. This is part of pi's own session storage; no extra setup needed.

## Troubleshooting

- **An agent has no status glyph / shows as stale**: check the hook/extension is
  actually writing `~/.local/share/aistatus/pid-<pid>.json` for that process — the
  file is keyed by the agent process's pid, not the tmux pane id.
- **"Last message" preview is empty or "(preview unavailable)"**: the session id in
  the aistatus file must match a real transcript/session file on disk. Check the
  path conventions above for the corresponding agent.
- **tmux not found**: Monica resolves `tmux`'s path via `zsh -lc 'command -v tmux'`
  once at startup, since GUI apps launched by launchd don't inherit your shell's
  `PATH`. Make sure `tmux` is on the `PATH` in a login shell.
