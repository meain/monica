# Setup

Monica doesn't talk to Claude Code or `pi` directly — it discovers live processes
from the tmux pane tree, then reads each agent's status:

- **Claude Code**: works out of the box — no configuration. Status comes from
  Claude Code's own live process registry, `~/.claude/sessions/<pid>.json`, which the
  CLI writes itself, so claude agents get a status glyph automatically.
- **`pi`**: needs the one-time `pi` tmux-status extension below, which writes
  `~/.local/share/aistatus/pid-<pid>.json`. Without it, a pi agent still shows up in
  the list (Monica can see the tmux pane and process) but without a status glyph.

So the only setup on this page is the `pi` extension, and only if you use `pi`. Monica
only reads these files — it never writes to them, so nothing breaks if you edit the
extension yourself.

## Claude Code

Nothing to set up. Monica reads Claude Code's own live process registry —
`~/.claude/sessions/<pid>.json`, which the CLI writes and keeps current itself (status,
working directory, session id, session name) — so claude agents show a status glyph
automatically.

The "last message" preview likewise reads Claude Code's own session storage,
`~/.claude/projects/<cwd, every non-alphanumeric char -> '-'>/<sessionId>.jsonl`,
directly — again, nothing to configure.

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
registration step needed beyond placing the file there. It reports two states:
`agent_start` maps to `working`, `agent_end` maps to `idle`.

Monica's "last message" preview for `pi` reads session files under
`~/.pi/agent/sessions/<"-" + cwd.replacingOccurrences(of: "/", with: "-") + "--">/`
— either a flat `<timestamp>_<sessionId>.jsonl` file, or (for resumed/branched
sessions) a `<timestamp>_<sessionId>` directory with nested `<hash>/run-N/session.jsonl`
files. This is part of pi's own session storage; no extra setup needed.

## Troubleshooting

- **A claude agent has no status glyph**: Claude Code writes
  `~/.claude/sessions/<pid>.json` for each live process on its own — confirm the file
  exists for that pid. If it doesn't, it's a Claude Code / version issue, not a Monica
  one.
- **A pi agent has no status glyph / shows as stale**: check the tmux-status extension
  is actually writing `~/.local/share/aistatus/pid-<pid>.json` for that process — the
  file is keyed by the agent process's pid, not the tmux pane id.
- **"Last message" preview is empty or "(preview unavailable)"**: the session id
  (from the sessions registry for claude, or the aistatus file for pi) must match a
  real transcript/session file on disk. Check the path conventions above for the
  corresponding agent.
- **tmux not found**: Monica resolves `tmux`'s path via `zsh -lc 'command -v tmux'`
  once at startup, since GUI apps launched by launchd don't inherit your shell's
  `PATH`. Make sure `tmux` is on the `PATH` in a login shell.
