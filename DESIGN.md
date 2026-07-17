# monica

A native macOS app for watching and switching between AI coding agents (Claude Code,
`pi`) running inside tmux panes. It is a GUI companion to the existing dotfiles
tmux-popup picker (`,tmux-ai-agents`), not a replacement — that fzf-based picker stays
as the fast keyboard-only path from inside tmux; monica adds a macOS-native layer that
works even when tmux isn't focused.

## Problem

`,tmux-ai-agents` already does this well inside tmux (`M-'` → fzf popup → pick an agent
→ `switch-client`). What it can't do: show status when tmux/the terminal isn't even
frontmost, or live in the menu bar. That's the gap monica fills.

## Prior art this borrows from

- `~/.dotfiles/scripts/.local/bin/tmux/,tmux-agent-scan` — the pid-tree walk (tmux
  pane → `pane_pid` → BFS over `ps` children looking for a process named `claude` or
  `pi`). monica ports this logic natively instead of shelling out to the script, so it
  has no dependency on dotfiles being present at a given path.
- `~/.dotfiles/claude/.claude/hooks/update-status.sh` and the `pi` tmux-status
  extension — write `~/.local/share/aistatus/pid-<pid>.json` with
  `{session_id, pid, status, hook_event, project, timestamp}`, `status` being
  `working` / `waiting` / `idle`. monica reads these as-is; it does not reimplement
  status detection.
- `~/dev/src/beacon` — SwiftPM (no Xcode), borderless `FloatingPanel` Spotlight-style
  popup, `LSUIElement` `.app` bundling via a `build-app.sh` + `Makefile`. monica's
  Spotlight popup and packaging are templated directly on this.
- `~/dev/src/mactraffic` — `NSStatusItem` + `NSPopover` menu bar pattern. monica's menu
  bar mode is templated on this.
- `~/dev/src/menutimer` — `flake.nix` devshell pattern (nix only provides dev tooling
  like `swift-format`; the Swift compiler itself comes from the system Xcode Command
  Line Tools, since nixpkgs' Swift on macOS is unreliable).
- `~/dev/src/dmux` (`native/macos/dmux-helper.swift`) — the more elaborate alternative
  we deliberately did *not* take for v1: Accessibility-API + OSC-2 window-title-token
  matching to disambiguate multiple windows of the same terminal app. Noted below as
  the natural upgrade path if the single-window assumption stops holding.

## Decisions made during planning

| question | decision |
|---|---|
| status data source | read `~/.local/share/aistatus/*.json` as-is; no new detection logic |
| pane/pid scanning | reimplement natively in Swift (no shelling out to dotfiles scripts) |
| relationship to `,tmux-ai-agents` | coexist — monica does not replace the tmux popup |
| notifications | out of scope for v1 — existing `notify-summary.sh` pipeline stays as-is |
| tmux scope | local tmux server(s) only, no SSH/remote |
| window switching | single-Ghostty-window assumption; no Accessibility-API disambiguation yet |
| overlay mode | a persistent HUD strip docked to the top edge, not a pinned popup |
| Spotlight trigger | native global hotkey (Carbon `RegisterEventHotKey`), default ⌃⌥⇧A, user-customizable |
| target app | configurable, defaults to Ghostty (`com.mitchellh.ghostty`) |
| agent scope | whatever's in the aistatus files today (Claude Code hook schema); can extend later |

## Architecture

```
AgentScanner (polls every 2s)
  ├─ tmux list-panes -a  ─┐
  ├─ ps -Ao pid,ppid,comm ┴─▶ pid-tree BFS per pane ──▶ candidate agent pid
  └─ ~/.local/share/aistatus/pid-<pid>.json  ────────▶ status/project/timestamp
        │
        ▼
  [AgentSession] (@Published, single shared store)
        │
   ┌────┼────────────────┬─────────────────────┐
   ▼                     ▼                     ▼
MenuBarController   HUDPanel              SpotlightPanel
(NSStatusItem        (borderless           (FloatingPanel,
 + popover,           always-on-top        global hotkey,
 aggregate glyph)     panel, top edge)      fuzzy filter)
   │                     │                     │
   └─────────────────────┴─────────────────────┘
                          ▼
                      Switcher
       tmux select-pane → resolve session:window →
       tmux list-clients → switch-client -c <client> -t <target> →
       open -a <configured app>
```

All three UI surfaces render the same `AgentListView` and call the same `Switcher`
action — they're different presentations of one shared `AgentStore`, not three
separate implementations.

### AgentSession model

Mirrors the TSV `,tmux-agent-scan` already emits, plus the aistatus fields:

```swift
struct AgentSession: Identifiable {
    var paneId: String        // e.g. "%12"
    var windowId: String      // e.g. "@4"
    var session: String
    var windowName: String
    var panePath: String
    var agentPid: Int32
    var agentName: String     // "claude" | "pi"
    var status: AgentStatus   // .working | .waiting | .idle
    var project: String
    var lastUpdated: Date?
}
```

### Status glyphs

Same as `,tmux-ai-agents`: `▶` working (green), `●` waiting (yellow), `○` idle (gray).
Menu bar aggregate glyph = highest-priority status across all sessions
(`working > waiting > idle`), same priority rule as `,tmux-claude-status`.

### Switching, precisely

`,tmux-ai-agents` gets away with a bare `tmux switch-client -t <target>` because it
runs *inside* a tmux popup, so there's an implicit "current client". monica runs
outside tmux entirely, so it must:

1. `tmux select-pane -t <paneId>`
2. Resolve `<session>:<windowId>` via `tmux list-windows -a -F '#{session_name}:#{window_id}'`
3. `tmux list-clients -F '#{client_name}'` → pick the (assumed single) attached client
4. `tmux switch-client -c <client_name> -t <session>:<windowId>`
5. `open -a <configured app>` to raise/activate the terminal

Known gap (accepted for v1): if multiple windows of the target app are open, step 5
may raise the wrong one. Fixing this means porting dmux's Accessibility-API +
OSC-2 title-token approach — deliberately deferred.

## File layout

```
monica/
  flake.nix              # devshell: swift-format only
  Package.swift           # swift-tools-version 6.0, macOS 14+
  Makefile                 # build / run / app / link / clean
  build-app.sh              # wraps release binary as monica.app (LSUIElement)
  DESIGN.md
  AGENTS.md
  Sources/monica/
    main.swift               # NSApplication bootstrap, AppDelegate, app menu
    AgentModels.swift          # AgentSession, AgentStatus
    AgentScanner.swift          # tmux+ps scan, aistatus lookup, polling, AgentStore
    Switcher.swift               # switch-client / select-pane / open -a
    AppSettings.swift             # UserDefaults-backed settings, shared singleton
    HotKeyManager.swift            # Carbon global hotkey registration
    AgentListView.swift             # shared SwiftUI row/list view
    MenuBarController.swift          # NSStatusItem + popover
    HUDPanel.swift                    # top-edge always-on-top strip
    SpotlightPanel.swift               # FloatingPanel + fuzzy filter
```

## Build / run

No Xcode project — SwiftPM only.

```bash
nix develop      # dev shell (swift-format)
make run         # swift run — build + launch
make app         # release build wrapped as monica.app
make link        # symlink monica.app into /Applications
```

## Future work (explicitly out of scope for v1)

- Accessibility-API window-title-token disambiguation for multiple target-app windows
  (port from `dmux-helper.swift`).
- Remote/SSH tmux visibility.
- Generic heuristic status detection (pane-content diffing) for agents without hook
  support, à la dmux's `paneAttentionHeuristics.ts`.
- monica owning desktop notifications (currently `notify-summary.sh`'s job); would
  enable focus-aware suppression (don't notify if the right window is already
  frontmost).
- Draggable/configurable HUD position (v1 is fixed to the top edge).
