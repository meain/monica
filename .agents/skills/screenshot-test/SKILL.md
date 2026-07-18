---
name: screenshot-test
description: "Visually test the monica GUI (popover or menu bar glyphs) by rendering it to a PNG (no screen-recording permission needed) and inspecting it. Use when verifying popover layout changes, menu bar glyph rendering, or reproducing a rendering bug."
user_invocable: true
---

# monica GUI screenshot testing

`screencapture` fails in the agent sandbox ("could not create image from display" — no
screen-recording permission). Instead monica renders **its own view** to a PNG from
inside the process (`MONICA_SHOT`/`MONICA_SHOT_MENUBAR` env vars), which needs no
permission — same technique as booker's `screenshot-test` skill.

## Usage

```sh
.agents/skills/screenshot-test/shot.sh popover                # render the popover
.agents/skills/screenshot-test/shot.sh popover /tmp/p.png 2    # select 2nd row first (Down x2)
.agents/skills/screenshot-test/shot.sh menubar                 # render just the glyph strip
.agents/skills/screenshot-test/shot.sh menubar /tmp/m.png
```

The script builds the debug binary, launches it with the right env var, optionally
drives `Down` arrow presses via System Events to change which row's preview shows, waits
for the render, and prints the PNG path. Then **`Read`** the PNG to inspect the actual
rendered layout.

## Why the row-selection option matters

The popover shows **real, live tmux/aistatus data** — whichever agents are actually
running on this machine, no demo-data seam. The first row's "Last message" preview can
end up showing the very session driving the test itself (self-referential/confusing for
a screenshot). Pass a row-down count to land on a different, more representative agent
before the shot fires.

## Knobs

- `MONICA_SHOT_DELAY` (default 1.5s) — total wait before the shot fires. First launch
  after a build is slower; increase if the PNG comes up empty/missing.

## When to use what

- **tmux/pid scanning logic** → headless commands against `tmux list-panes` / `ps` /
  `~/.local/share/aistatus/*.json` directly (no GUI needed) — see AGENTS.md.
- **Popover/menu-bar layout** → this skill (render to PNG + Read).
- **Window geometry (size/position) only** → `CGWindowListCopyWindowInfo` scratch
  script in AGENTS.md — no rendering needed, just bounds.

See `AGENTS.md`'s "Verifying the GUI" section for the full technique writeup.
