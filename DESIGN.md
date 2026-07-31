# monica

A native macOS app for watching and switching between AI coding agents (Claude Code,
`pi`) running inside tmux panes. It is a GUI companion to the existing dotfiles
tmux-popup picker (`,tmux-ai-agents`), not a replacement — that fzf-based picker stays
as the fast keyboard-only path from inside tmux; monica adds a macOS-native layer that
works even when tmux isn't focused.

**v1.1 note:** the original plan had three UI surfaces (menu bar, an always-on HUD
strip, and a separate Spotlight popup). After using v1, that collapsed to one: a single
menu bar popover (search + list + Settings/Quit), opened either by clicking the status
item or via the global hotkey. The HUD strip added visual clutter for no real benefit
over the menu bar title glyph, and a second picker UI was redundant once the popover had
search. See "Decisions made during planning" for what changed and why.

**v1.2 note:** real usage surfaced several polish items, all folded into the same
popover: single-line rows (was two lines) in a wider popover so more fits at once; the
list sizes itself to how many agents are actually showing rather than always reserving
its old fixed height, capped at 60% of the screen height for when there are a lot;
arrow-key selection scrolls into view; a distinct `◌` glyph for agents that haven't
updated their status in 3h+; the message preview renders as markdown; a "Quickstart"
section in Settings; and the app displays as "Monica" (capitalized) rather than lowercase
`monica` everywhere the UI shows its name (the package/binary/bundle-file name stay
lowercase — see "File layout").

**v1.3 note:** fixing v1.2's polish items piecemeal (padding, then a scrollbar-shift
issue, then a redundant hint row) kept surfacing the same root cause — the popover's
view code was one large monolithic `body` in `MenuBarController.swift` with ad-hoc
padding literals per section. Refactored into `PopoverLayout.swift` (shared width/inset
constants + a `popoverSection()` modifier) and `MenuBarPopoverView.swift` (one small
`View` struct per section), with `MenuBarController.swift` trimmed back to pure
`NSStatusItem`/`NSPopover` mechanics. The redundant "↩ switch · ⌘↩ send message" hint
row was also dropped from the popover — it's covered by Settings' Quickstart section
now. Settings itself got the same "Quickstart" treatment noted above but needed a
follow-up fix (see "Settings window sizing"). The scrollbar-shift issue's first fix
(`.scrollIndicators(.hidden)`) turned out to be incomplete — see "Scrollbars:
`.scrollIndicators(.hidden)` isn't enough".

**v1.4 note:** the status source and status model both changed. **Claude Code agents
now read their status from Claude Code's own live process registry,
`~/.claude/sessions/<pid>.json`** (`status: busy`/`idle`, `cwd`, `sessionId`, `name`,
`updatedAt`), not from the hook-driven aistatus file — the registry is written by the
CLI itself rather than by a hook that has to fire, so it's fresher and more reliable
(and monica was already reading that file for the session name, so it's one read
instead of two). `pi` has no such registry and still reads aistatus. In tandem, the
**`waiting` status was removed entirely** — the registry only distinguishes `busy`/`idle`,
so a separate "blocked on you" state can't be told apart reliably. There are now two
live states, `working` (registry `busy`) and `idle` (everything else — finished its turn,
awaiting you); pi's old aistatus `waiting` collapses into `idle`. The 15m "quiet" and 3h
"stale" time-based overlays are unchanged. The jump hotkey and "Needs attention" sort,
both previously built around `waiting`, now target `idle` (the agent awaiting you).

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
  `{session_id, pid, status, hook_event, project, timestamp}`. This is now the status
  source for `pi` only; **claude** reads Claude Code's own
  `~/.claude/sessions/<pid>.json` registry instead (see the v1.4 note and
  `AgentScanner.lookupStatus`). monica reads both as-is; it does not reimplement status
  detection.
- `~/dev/src/beacon` — SwiftPM (no Xcode), borderless `FloatingPanel` Spotlight-style
  popup, `LSUIElement` `.app` bundling via a `build-app.sh` + `Makefile`. monica's
  packaging is templated directly on this, and its `PickerModel` (an AppKit local
  event monitor for arrow/return/escape, since SwiftUI's `.onKeyPress` doesn't reliably
  receive focus in a popover/panel) is the basis for `AgentPickerModel`.
- `~/dev/src/mactraffic` — `NSStatusItem` + `NSPopover` menu bar pattern, including
  setting an **explicit `popover.contentSize`** rather than letting `NSPopover` guess
  one from the hosted SwiftUI view. monica initially skipped this and paid for it (see
  "Decisions made during planning").
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
| status data source | **claude**: Claude Code's `~/.claude/sessions/<pid>.json` registry; **pi**: `~/.local/share/aistatus/*.json`. Read as-is, no new detection logic (v1.4) |
| pane/pid scanning | reimplement natively in Swift (no shelling out to dotfiles scripts) |
| relationship to `,tmux-ai-agents` | coexist — monica does not replace the tmux popup |
| notifications | out of scope for v1 — existing `notify-summary.sh` pipeline stays as-is |
| tmux scope | local tmux server(s) only, no SSH/remote |
| window switching | single-Ghostty-window assumption; no Accessibility-API disambiguation yet |
| number of UI surfaces | **v1.1: one** — the menu bar popover. Dropped the always-on HUD strip and the separate Spotlight window (see below) |
| global hotkey | opens/toggles the *same* menu bar popover — not a second picker UI |
| picker search | a search field inside the popover filters the agent list (ported from the old Spotlight popup) |
| Settings | a proper `NSWindow` (not a panel), opened from a footer row in the popover; lets you re-record the hotkey and change the target app |
| target app | configurable in Settings (text field + an "Choose…" `NSOpenPanel`), defaults to Ghostty (`com.mitchellh.ghostty`) |
| Spotlight hotkey default | native global hotkey (Carbon `RegisterEventHotKey`), default ⌃⌥⇧A, re-recordable live from Settings |
| agent scope | claude (via the sessions registry) and pi (via aistatus); can extend later |
| message send | ⌘Return on a row composes a message sent via `tmux send-keys`, mirroring `,tmux-ai-agents`'s `alt-enter` |
| message preview | reads each agent's own transcript file directly (keyed by `session_id`), not the status file — neither the aistatus nor the sessions file carries message content |

**Why the HUD/Spotlight-window surfaces got dropped:** using v1 for real showed the HUD
strip's one-glyph-per-agent display could just as well live in the menu bar title
itself — no need for a separate always-on-top window to show the same information. The
Spotlight popup, once it grew a search field, was doing exactly what the menu bar
popover could do — so the hotkey now just opens that popover instead of a second,
nearly-identical window.

**The positioning bug:** the menu bar popover used to open ~180pt below the status item
instead of right beneath it. Root cause: `NSPopover` was never given an explicit
`contentSize`, so it had to guess one from the hosted SwiftUI view before its first
layout pass; that ambiguous guess corrupted the anchor math. Fixed by setting
`popover.contentSize` explicitly at init, matching mactraffic's `StatusBarController`.

## Architecture

```
AgentScanner (polls every 2s)
  ├─ tmux list-panes -a  ─┐
  ├─ ps -Ao pid,ppid,comm ┴─▶ pid-tree BFS per pane ──▶ candidate agent pid
  └─ claude: ~/.claude/sessions/<pid>.json ──────────▶ status/project/timestamp/name
     pi:     ~/.local/share/aistatus/pid-<pid>.json ─▶ status/project/timestamp
        │
        ▼
  scanner.sessions
        │
        ▼
MenuBarController (NSStatusItem: one glyph per agent, e.g. "▶ ● ○")
        │  click icon ──┐
        │  global hotkey┤──▶ togglePopover()
        │               │
        ▼               ▼
   NSPopover: search field → AgentPickerModel.filteredSessions → AgentListView
        │                                                            │
        │                                    click a row / Return    │  ⌘Return
        │                                                            ▼        ▼
        │                                                        Switcher   compose mode:
        │                                          tmux select-pane → resolve  search field →
        │                                          session:window → tmux      message field,
        │                                          list-clients → switch-client Return sends via
        │                                          -c <client> -t <target> →   Switcher.sendMessage
        │                                          open -a <configured app>    (tmux send-keys),
        ▼                                                                     Escape cancels back
  footer: "Settings…" → SettingsWindowController (NSWindow)                   to search
          "Quit monica"
```

Settings changes flow back in one direction: editing the target app writes straight to
`AppSettings` (read by `Switcher` on the next switch); re-recording the hotkey writes to
`AppSettings` *and* calls back into `AppDelegate.registerHotKey()` to re-register with
Carbon immediately, so it takes effect without restarting the app.

### AgentSession model

Mirrors the TSV `,tmux-agent-scan` already emits, plus the per-agent status fields:

```swift
struct AgentSession: Identifiable {
    var paneId: String        // e.g. "%12"
    var windowId: String      // e.g. "@4"
    var session: String
    var windowName: String
    var panePath: String
    var agentPid: Int32
    var agentName: String     // "claude" | "pi"
    var status: AgentStatus   // .working | .idle
    var project: String
    var lastUpdated: Date?
}
```

### Status glyphs

`▶` working (green), `○` idle (gray). The menu bar title shows one glyph per agent
(e.g. `▶ ○ ○` for one working, two idle) — this is what the old HUD strip showed, now
living directly in the title instead of a separate window. `AgentStatus`'s `Comparable`
conformance (`working > idle`) is used elsewhere (e.g. sort order) but no longer
collapses the title to a single aggregate glyph. (The old yellow `●` `waiting` glyph is
gone — see the v1.4 note.)

Two more glyphs on top of those two, both time-based overlays that override whatever the
`status` value says: `●` (filled gray dot) once `lastUpdated` is 15m–3h old ("quiet"),
and `◌` (dotted circle) once it's more than 3h old ("stale") — a `working` status from
5 hours ago is more likely a dead/abandoned session than one still wanting attention.
This is a display-layer decision
(`AgentSession.isQuiet`/`isStale`/`displayGlyph`) — `AgentScanner` itself no longer
discards old-but-real timestamps the way `,tmux-ai-agents`' 2h `STALE_SECS` cutoff does,
since the pid-tree scan already guarantees the pid is still a live process (see
`AgentScanner.lookupStatus`'s doc comment).

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

### Sending a message without switching (⌘Return)

Mirrors `,tmux-ai-agents`'s `alt-enter` binding
(`tmux send-keys -t {3} "$msg" Enter`), which sends text into a pane without switching
focus to it — useful for nudging an agent that's `idle` (awaiting you) without leaving
what you're doing. In the popover: ⌘Return on a selected row swaps the search field for a message
field (`AgentPickerModel.composeTarget`); plain Return sends via
`Switcher.sendMessage(_:text:)` (`tmux send-keys -t <paneId> <text> Enter`) and closes
the popover; Escape cancels back to the search field instead of closing the popover.

### Message preview (selected row only)

Neither status file carries message content (aistatus is `{session_id, pid, status,
hook_event, project, timestamp}`; the claude sessions registry has status/cwd/name but
no messages) — the preview instead reads each agent's *own* transcript file directly,
keyed by that `session_id`:

- **Claude Code**: `~/.claude/projects/<cwd, every non-alphanumeric char → '-'>/<sessionId>.jsonl`.
  Confirmed against real transcripts on this machine and against public docs (the
  format is `type: "user"|"assistant"|"system"` lines with `message.content` blocks of
  type `text`/`thinking`/`tool_use`). This is the exact same file and the exact same
  "search backward for the last assistant message's text blocks" logic
  `notify-summary.sh` already uses.
- **pi**: `~/.pi/agent/sessions/<"-" + cwd.replacingOccurrences(of: "/", with: "-") + "-->/`,
  then either a flat `<timestamp>_<sessionId>.jsonl` file directly in that directory (the
  common case — confirmed on this machine that *most* sessions are stored this way), or
  — for sessions that got resumed/branched — a `<timestamp>_<sessionId>` *directory*
  holding nested `<hash>/run-N/session.jsonl` files instead. Both shapes were found side
  by side on this machine; `latestPiSessionFile` checks the flat file first, falling back
  to the most-recently-modified nested one. pi's session format
  ([pi.dev/docs/latest/session-format](https://pi.dev/docs/latest/session-format)) is
  overall a branching id/parentId tree — this is best-effort and just reads file order,
  ignoring branches.

Both directory-name encodings were reverse-engineered empirically (directory names on this machine)
and cross-checked against public documentation — see `TranscriptPreview.swift`'s doc
comment for the exact rules. Only the tail of the transcript (last ~200KB) is read, to
avoid loading a long-running session's multi-MB file into memory just to preview it.

Only `AgentPickerModel.previewText` for the *currently selected* row is computed (on
selection change and on each scan refresh while the popover is open) — not all rows at
once, since it's synchronous file I/O on the main thread. Cheap enough for a single
tail-read per change; would need to move to a background queue if that ever changes.

The preview renders as markdown (`MarkdownPreviewText`, backed by SwiftUI's native
`AttributedString(markdown:)`) rather than plain text, since Claude Code/pi assistant
messages usually *are* markdown. One `Text(AttributedString)` for the whole document
doesn't work, though — confirmed visually (a real screenshot showed
"GreenHighlightsCurrentStatusHitesh", several separate headings/lines glued together
with no separator at all). `Text` only honors per-character formatting from a parsed
`AttributedString`, not block-level structure — SwiftUI ignores `presentationIntent`, so
paragraph/heading breaks vanish. `MarkdownPreviewText` instead splits the raw text into
lines first and renders each as its own `Text` in a `VStack`, which is what actually
preserves the breaks (at the cost of not flowing a hard-wrapped multi-line paragraph as
one block — acceptable for LLM output, which doesn't hard-wrap prose). This is
deliberately lighter than beacon's full custom markdown engine (`MarkdownParser`/
`MarkdownView`/`SyntaxHighlighter`) — bold/italic/links/headings render per line, but
fenced code blocks don't get syntax highlighting (just plain text) and multi-line lists
lose their shared indentation context. Acceptable for a small preview panel; would need
beacon's approach ported over if that becomes the primary content surface.

### Sizing: content-driven, not always maximal

The popover was originally a small fixed size, then briefly *always* sized to 60% of
the screen height regardless of agent count (per an early version of this feature) —
both wrong in different ways. `MenuBarController.resizeForScreen()` instead sizes the
list to how many agents are actually showing (`rowCount * agentRowHeight`), only
clamping at 60% of the screen height as a ceiling for when there are a lot. Recomputed
on every `openPopover()` since the agent count can change between opens.

### Settings window sizing

`SettingsView` uses `Form { ... }.formStyle(.grouped)` for the boxed-section look (like
System Settings.app) instead of the original plain `Form`. That style change broke
`NSWindow(contentViewController:)`'s auto-sizing — the window collapsed to ~32pt tall
(just the titlebar, no content at all), confirmed via a real screenshot, not a compiler
warning. The plain-style Form had auto-sized correctly; `.formStyle(.grouped)` apparently
doesn't report a usable ideal height the same way. Fixed with an explicit
`.frame(width: 460, height: 640)` — tall enough that all four sections fit without the
Form's internal List needing to scroll at all (an earlier, shorter guess at the height
still left it scrolling, just with a hidden-but-functional scrollbar — see below).

### Scrollbars: `.scrollIndicators(.hidden)` isn't enough

Both the "Last message" preview panel and (potentially, if content ever overflows)
Settings' grouped `Form` showed a persistent scrollbar thumb *despite*
`.scrollIndicators(.hidden)` being applied — confirmed via a real screenshot, not
something that shows up any other way. Root cause: that modifier only controls SwiftUI's
newer overlay-indicator API. Once content actually overflows under a non-overlay-style
scrollbar (`defaults read NSGlobalDomain AppleShowScrollBars` — "Always"/"WhenScrolling",
or "Automatic" once scrolling happens), AppKit still attaches a classic `NSScroller` to
the underlying `NSScrollView`, which SwiftUI's modifier doesn't override. That legacy
scroller is also what reserves layout width and shifts content when it appears/
disappears — the original "everything gets thrown out of whack" complaint that
`.scrollIndicators(.hidden)` was meant to fix in the first place.
`ScrollbarSuppressor.swift` (an `NSViewRepresentable` embedded as
`.background(ScrollbarSuppressor())` on the scrollable *content*, not the `ScrollView`
itself) walks up to the real `NSScrollView` and sets `hasVerticalScroller`/
`hasHorizontalScroller = false` and `scrollerStyle = .overlay` directly — that's the
authoritative state `.scrollIndicators(.hidden)` doesn't fully control. Used in both
`AgentListSection`/`LastMessageSection` (`MenuBarPopoverView.swift`) and the Quickstart
section of `SettingsView` (any `.formStyle(.grouped)` `Form` is List-backed and has the
same issue).

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
    AgentScanner.swift          # tmux+ps scan, status lookup (claude sessions / pi aistatus), polling, AgentStore
    Switcher.swift               # switch-client / select-pane / open -a
    AppSettings.swift             # UserDefaults-backed settings, shared singleton
    HotKeyManager.swift            # Carbon global hotkey registration
    HotKeyFormatter.swift           # keyCode+modifiers -> display label ("⌃⌥⇧A")
    KeyRecorderView.swift            # hotkey re-recording control, used in Settings
    AgentListView.swift               # shared SwiftUI row/list view, agentRowHeight constant
    AgentPickerModel.swift             # popover search + keyboard nav + compose + preview state
    TranscriptPreview.swift             # reads last message from each agent's own transcript
    MarkdownPreviewText.swift            # renders preview text as markdown
    PopoverLayout.swift                   # shared width/inset constants + popoverSection() modifier
    ScrollbarSuppressor.swift              # NSViewRepresentable forcing overlay/hidden scrollers
    MenuBarPopoverView.swift                # popover SwiftUI content, one View struct per section
    MenuBarController.swift                  # NSStatusItem + NSPopover mechanics only, no view code
    SettingsView.swift                        # SettingsView (+ Quickstart) + SettingsWindowController
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
- Launch-at-login toggle (currently manual — `open -a monica` or Login Items).
