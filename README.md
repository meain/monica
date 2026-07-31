# Monica

<img align="right" width="400" src="https://github.com/user-attachments/assets/9f703ab8-cd9d-4102-ae8d-99f8d672a696" alt="Monica popover">

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

## More

See `AGENTS.md` for build/test details and a list of non-obvious gotchas, and
`DESIGN.md` for the full architecture and design decisions.
