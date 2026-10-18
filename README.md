# Monica

<img align="right" width="400" src="https://github.com/user-attachments/assets/13e69ad5-207d-439f-9799-c9e0b2eba0cf" alt="Monica popover">

A macOS menu bar app for watching and switching between AI coding agents (Claude
Code, `pi`) running inside tmux panes.

## What it does

Monica sits in your menu bar as a status item showing one glyph per agent, reflecting
whether each is working or idle (plus a dimmed glyph once an agent has gone quiet):

![Menu bar status glyphs](https://github.com/user-attachments/assets/eee6ac36-6bfd-430a-9c57-9aa7018117ed)

Click the icon, or press a global hotkey, to open a popover with:

- a searchable list of all agents across your tmux sessions, with status and
  last-updated time
- a preview of each agent's last message
- Return to switch tmux to that agent's pane
- ⌘Return to compose a message and send it into the pane without switching

## Requirements

- macOS 14+
- tmux, with Claude Code and/or `pi` running in tmux panes
- Status data is read-only: for Claude Code it comes from Claude Code's own
  `~/.claude/sessions/` process registry; for `pi` it comes from the `pi` tmux-status
  extension's `~/.local/share/aistatus/` files. Monica never writes to either. See
  [docs.md](docs.md) for how to set up `pi`'s status extension.

## Build & run

No Xcode project — this uses SwiftPM directly.

```bash
nix develop   # devshell
make run      # swift run — build + launch
make build    # debug build
make app      # release build wrapped as monica.app (LSUIElement, no dock icon)
make link     # symlink monica.app into /Applications
```

## CLI

The same binary is a CLI when given a command (bare `monica` launches the app). It
scans tmux directly, so it works with or without the app running.

```bash
make link-cli                  # symlink the app's binary to ~/.local/bin/monica
monica ls [--json] [--status waiting]
monica show <target>           # details + last message
monica focus <target>          # switch tmux to the pane, raise the terminal
echo "run the tests" | monica send <target> --wait   # send, block until the turn ends
monica tail <target> -n 30     # what's on the agent's screen
monica wait <target> --timeout 600
```

`<target>` is a pane id (`%12`), a pid, or a substring of the agent's name/project/tmux
session/window that matches exactly one agent. `wait`/`send --wait` exit 0 when the
agent finishes, 3 if it's blocked waiting on you, 124 on timeout. Input that never starts
a turn (`/clear`) makes `send --wait` return after a 5s grace period. `ls` marks your own
pane (from `$TMUX_PANE`) and `send` refuses it without `--force`.

## More

See `AGENTS.md` for build/test details and a list of non-obvious gotchas, and
`DESIGN.md` for the full architecture and design decisions.
