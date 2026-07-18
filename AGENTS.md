# AGENTS.md

Guidance for AI agents working on **monica** — a macOS menu bar app for watching and
switching between AI coding agents (Claude Code, `pi`) running inside tmux panes. See
`DESIGN.md` for the full architecture and the decisions made during planning — read it
first, especially the "v1.1"/"v1.2"/"v1.3" notes at the top.

The popover's view code lives in `MenuBarPopoverView.swift` (one small `View` struct per
section) plus `PopoverLayout.swift` (shared width/inset constants and a
`popoverSection()` modifier) — `MenuBarController.swift` is purely `NSStatusItem`/
`NSPopover` mechanics now, no SwiftUI layout code. If you're adding a new section to the
popover, use `PopoverLayout.horizontalInset`/`popoverSection()`, don't hardcode a padding
value that happens to look right in isolation — that's exactly how the popover ended up
with three different left margins across sections before (see the gotcha below).

## What this is

A SwiftUI/AppKit app: one `NSStatusItem` whose title shows one status glyph per agent
(e.g. `▶ ● ○`), and one `NSPopover` (search field + agent list + Settings/Quit footer)
that both a click on the icon and a global hotkey open — there is deliberately only one
picker UI, not separate HUD/Spotlight surfaces (an earlier version had those; see
DESIGN.md for why they were removed). Return on a selected row switches to that agent's
pane; ⌘Return instead composes a message to send into the pane without switching (see
"Sending a message" in DESIGN.md). It is a GUI companion to the existing
`,tmux-ai-agents` fzf picker in `~/.dotfiles`, not a replacement — both coexist.

## Build / run / test

No Xcode (Command Line Tools only) — use **SwiftPM**, not `xcodebuild`.

```bash
nix develop   # devshell: swift-format only (compiler is the system Xcode CLT)
make run      # swift run — build + launch
make build    # debug build
make app      # release build wrapped as monica.app (LSUIElement, no dock icon)
make link     # symlink monica.app into /Applications (tracks the build)
```

`Package.swift` pins Swift language mode **v5**, deliberately — full Swift 6 strict
concurrency fights the AppKit/Carbon/Process callback patterns here (opaque Carbon refs
touched from `deinit`, an `ObservableObject` singleton, custom `AppDelegate` methods
that touch `@MainActor` types). Same call beacon made for the same reason. Custom
`AppDelegate` methods beyond the protocol requirements (`registerHotKey()`,
`showSettings()`) need an explicit `@MainActor` annotation — only the protocol-required
methods like `applicationDidFinishLaunching` get MainActor isolation for free from the
AppKit overlay.

### Verifying the tmux/pid scanning logic without the GUI

The scanner's core logic (tmux pane listing, pid-tree BFS, aistatus lookup) has no
UI dependency. If you change `AgentScanner.swift`, sanity-check the underlying
commands directly:

```bash
tmux list-panes -a -F '#{pane_id}\t#{window_id}\t#{session_name}\t#{pane_pid}'
ps -Ao pid,ppid,comm
cat ~/.local/share/aistatus/pid-<pid>.json
```

### Verifying the GUI

`screencapture` from the CLI is usually **blocked** (no Screen Recording permission) —
confirmed by `screencapture -x`/`-l <windowID>` both failing with "could not create
image from display/window". But you *can* render the actual UI to a PNG without that
permission at all, same technique as `booker`'s `BOOKER_SHOT` (see booker's AGENTS.md):
the app renders **its own view** to an offscreen bitmap via `NSView.cacheDisplay(in:to:)`
+ `bitmapImageRepForCachingDisplay`, which needs no OS permission since it's not
capturing the screen, just asking AppKit to draw the view into a buffer.

`main.swift` wires this up behind two env vars, both gated so they have zero effect on
normal launches:

```bash
# Popover (search + list + preview + footer):
MONICA_SHOT=/tmp/shot.png MONICA_SHOT_DELAY=1.5 ./.build/debug/monica &
# Menu bar glyph strip only:
MONICA_SHOT_MENUBAR=/tmp/menubar.png ./.build/debug/monica &
```

The app opens the popover (or just reads the status item), waits `MONICA_SHOT_DELAY`
seconds (default 1.5s — first launch after a build is slower; retry with more delay if
the file comes up empty/missing), renders, writes the PNG, and self-terminates. Then
`Read` the PNG to inspect the actual rendered layout — this is the reliable way to
verify SwiftUI layout here, not a last resort.

The rendered popover reflects **real, live tmux/aistatus data** from whatever agents
are actually running on this machine — there's no demo-data seam like booker's
`BOOKER_BM_FILE`. That's usually fine (it's the same dogfood data the real screenshots
in `docs/` show), but the *selected* row's "Last message" preview can end up showing
the very session you're using to drive this test (self-referential/confusing for a
README screenshot). Drive a `Down`/`Up` arrow via System Events first to select a
different row before the shot fires if that happens:

```bash
osascript -e 'tell application "System Events" to key code 125'  # Down arrow
```

Check `/tmp/monica.log` (or whatever log you redirect stdout/stderr to) for crashes if
a plain headless launch is all you need:

```bash
./.build/debug/monica > /tmp/monica.log 2>&1 &
```

The menu bar item should appear within a couple seconds (first scan happens on
launch).

**You can verify window geometry (size/position) without screenshotting** via
`CGWindowListCopyWindowInfo`, run through a scratch script:

```bash
cat > /tmp/checkwin.swift <<'EOF'
import CoreGraphics
import Foundation
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly)
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { exit(0) }
for w in list {
    // Owner name is "Monica" (capitalized display name — see the display-string
    // gotcha below), not lowercase "monica"; a lowercase `.contains` check here
    // silently matches nothing.
    if let owner = w[kCGWindowOwnerName as String] as? String, owner == "Monica" {
        print(w[kCGWindowName as String] ?? "(no name)", w[kCGWindowBounds as String] ?? "")
    }
}
EOF
swift /tmp/checkwin.swift
```

and get the menu bar item's own position/size via Accessibility:

```bash
osascript -e 'tell application "System Events" to tell process "monica" to get position of menu bar item 1 of menu bar 2'
osascript -e 'tell application "System Events" to tell process "monica" to click menu bar item 1 of menu bar 2'  # opens the popover
```

This combination is exactly how the popover mis-positioning bug (below) was caught and
confirmed fixed — compare the popover's `Y` to the menu bar item's `Y`, they should be
within a few points of each other.

**Element-based Accessibility queries can't reach inside the popover — but coordinate
clicks can.** `System Events`'s `windows`/`buttons`/`entire contents` enumeration for
the "monica" process returns nothing useful for SwiftUI content, in the popover *and*
in plain titled windows like Settings (confirmed both return empty). But
`click at {x, y}` (raw screen coordinates, not an AX element reference) still reaches
and activates real SwiftUI buttons — get the popover's frame from
`CGWindowListCopyWindowInfo`, compute an approximate row position, and click there. This
is how the Settings window and the send-message compose mode were verified to actually
open, despite not being able to read their contents afterward. You still can't read text
back this way — for that, ask the user for a screenshot.
Keystrokes (`key code`) and typed text (`keystroke`) also reach the app's key window
fine regardless of this limitation — it's specifically *element lookup/enumeration*
that fails for SwiftUI content, not input delivery.

## Non-obvious gotchas

- **Images for README/docs.md are never committed to the repo** — they're uploaded via
  the `gh image` extension (`gh extension install drogers0/gh-image`; authenticates via
  your browser's `user_session` cookie, no PAT scopes) to GitHub's `user-attachments`
  CDN and also posted as a comment on the
  [meain/monica#4 "Media"](https://github.com/meain/monica/issues/4) tracking issue for
  a durable history: `gh image <file>.png --repo meain/monica` prints a ready-to-paste
  `![...](https://github.com/user-attachments/assets/...)` line and URL, then
  `gh issue comment 4 --repo meain/monica --body "..."` records it. Use that URL
  directly in README.md/docs.md — don't add the PNG to `docs/`. See the
  `update-readme-screenshot` skill for the scripted version of this for the popover
  screenshot specifically.
- **The aistatus files have no message content** (`session_id`, `pid`, `status`,
  `hook_event`, `project`, `timestamp` — that's it). The "Last message" preview instead
  reads each agent's own transcript file directly, keyed by `session_id`. The two
  agents use *different* directory-name encodings for the same `cwd`, both
  reverse-engineered empirically against real directories on this machine and
  cross-checked against public docs — don't assume they match, and don't guess a new
  one without checking real files under `~/.claude/projects/` or
  `~/.pi/agent/sessions/` first. See `TranscriptPreview.swift`'s doc comment for the
  exact rules.
- **`NSPopover.contentSize` is a hint, not a hard clamp.** The popover's measured window
  is consistently a bit larger than the `contentSize` set in `MenuBarController.swift`
  (e.g. requested 320×400, measured ~346×410) — that's just the popover's own
  border/arrow chrome, not a content-overflow bug. Confirmed by tightening a
  suspected-overflowing view's width and seeing zero change in the measured total. Don't
  chase that gap; instead verify actual rendering via a real screenshot from the user.
- **`Switcher.sendMessage` fires real `tmux send-keys` into a live pane** — during
  testing, verify the ⌘Return compose-mode UI flow (entering compose, typing, Escape to
  cancel) via Accessibility scripting, but don't press the final plain-Return that
  actually sends unless you mean to inject text into one of the user's real tmux
  sessions (which may well be running an actual Claude Code/`pi` conversation). Ask the
  user to test the send step themselves.
- **GUI environment lacks the nix profile PATH.** Apps launched by launchd get a
  minimal environment. tmux lives at `~/.nix-profile/bin/tmux` on this machine, not on
  launchd's default PATH. `ProcessUtil.swift`'s `TmuxCLI.path` resolves it once via
  `zsh -lc 'command -v tmux'`. Don't switch tmux invocations back to a bare
  `Process(launchPath: "/usr/bin/env", arguments: ["tmux", ...])` — it will silently
  find nothing.
- **Switching runs outside tmux**, unlike `,tmux-ai-agents` (which runs inside a tmux
  popup and can rely on an implicit "current client" for `switch-client -t`). monica
  has to name a client explicitly via `tmux list-clients` — see `Switcher.swift` and
  DESIGN.md's "Switching, precisely" section. It assumes a single attached client
  (single target-app window); don't "fix" this by guessing which client without first
  reading the multi-window disambiguation note in DESIGN.md's future-work section.
- **`NSPopover` needs an explicit `contentSize`.** Without one, `MenuBarController`'s
  popover opened ~180pt below the status item instead of right beneath it — it had to
  guess a size from the hosted SwiftUI view before any layout pass, and that ambiguous
  guess corrupted the anchor math. Fixed by setting `popover.contentSize` once at init
  (see `MenuBarController.swift`), matching mactraffic's `StatusBarController`. Don't
  remove that explicit size without re-verifying position via the geometry check above.
- **A SwiftUI `ScrollView` given only `.frame(maxHeight:)` reports zero ideal height**
  to its hosting window/popover (no intrinsic content size). The popover's list uses a
  real `.frame(height:)` for this reason — don't revert to `maxHeight` alone.
- **Global hotkey uses Carbon (`RegisterEventHotKey`)**, not an `NSEvent` global
  monitor — deliberately, since Carbon hotkeys don't require Accessibility/Input
  Monitoring permission. `HotKeyManager.swift`. It opens the *same* popover
  `togglePopover()` that a click does — there is no separate hotkey-triggered window.
- **⌃⌥⌘ + letter is very likely already claimed by Hammerspoon** on this machine (it's
  the user's "hyper key" prefix for many bindings) and `RegisterEventHotKey` fails
  *silently* in that case — no error, the hotkey just never fires. This is why the
  default hotkey is ⌃⌥⇧A, not ⌃⌥⌘A. If a hotkey seems dead, check for a modifier
  collision before assuming the registration code is broken. The hotkey is
  re-recordable live from Settings (`KeyRecorderView.swift`) — changing it calls back
  into `AppDelegate.registerHotKey()`, which re-registers with Carbon immediately.
- **Status data is read-only.** monica never writes to `~/.local/share/aistatus/` —
  those files are produced by Claude Code hooks / the `pi` tmux-status extension in
  `~/.dotfiles`. If status looks wrong, check the hook scripts there, not this repo.
- **pi session files come in two different shapes, both real, found side by side on
  this machine**: usually a flat `<timestamp>_<sessionId>.jsonl` file directly in the
  project directory, but sometimes (resumed/branched sessions) a
  `<timestamp>_<sessionId>` *directory* holding nested `<hash>/run-N/session.jsonl`
  files instead. `TranscriptPreview.latestPiSessionFile` checks the flat file first.
  This was an actual bug (`(preview unavailable)` for every pi agent) caught by testing
  against a real live pi session (find one via `hook_event: "agent_end"`/`"agent_start"`
  in an aistatus file — that's pi's naming, distinct from Claude's `Stop`/`Notification`/
  etc.) rather than assuming the one example found during initial development
  generalized.
- **`AgentScanner.lookupStatus` no longer discards old timestamps** (removed the
  `,tmux-ai-agents`-inherited 2h `STALE_SECS` cutoff) — old-but-real data now flows
  through to `AgentSession.lastUpdated` so the 3h staleness glyph (`◌`) has something to
  check. Don't reintroduce an early cutoff there; if staleness handling needs to change,
  change the 3h threshold in `AgentModels.swift`'s `isStale`, not the scanner.
- **The app displays as "Monica"** (capitalized) in all user-facing text — window
  titles, menu items, `CFBundleName`/`CFBundleDisplayName` — but the Swift package,
  executable, `.app` bundle filename, bundle identifier (`com.meain.monica`), and
  `UserDefaults` keys all stay lowercase `monica`. Don't rename those without a good
  reason; it's purely a display-string change, not a project rename.
- **The menu bar title glyphs must all come from one font — SF monospaced silently
  lacks `◌` (U+25CC).** With `NSFont.monospacedSystemFont`, the stale glyph fell back
  to Menlo-Bold while `▶ ● ○` stayed SF; measured glyph boxes differ by ~1.2pt
  vertically (SF `○` spans 0.6–8.6pt above baseline, Menlo `◌` −0.5–7.3pt), so the
  dotted circles sat visibly off-center next to the others — caught only via a
  screenshot, no warning anywhere. `MenuBarController.updateTitle()` therefore uses
  Menlo explicitly, which covers all four glyphs. If you change the glyph set, check
  actual font coverage with `CTFontCreateForString` (a scratch script, run via
  `env -u SDKROOT -u DEVELOPER_DIR /usr/bin/swift`) before assuming the system font
  renders it.
- **A single `Text(AttributedString)` does not render markdown block structure** —
  SwiftUI ignores `presentationIntent`, so multiple headings/paragraphs parsed into one
  `AttributedString` display with *no* separator between them at all (caught via a real
  screenshot: "GreenHighlightsCurrentStatusHitesh", several distinct lines glued
  together). `MarkdownPreviewText.swift` splits the raw text into lines first and
  stacks one `Text` per line in a `VStack` — don't revert to a single whole-document
  `Text` without re-verifying via a screenshot, this exact bug has no compiler or crash
  signal, it only shows up visually.
- **Left-margin consistency across sections needs an explicit shared inset, not
  independent per-section padding.** The popover's root `VStack` had no `alignment:`
  parameter → defaulted to `.center`, and the search field, list rows, and preview panel
  each had their own ad-hoc padding (8pt vs. 4+10=14pt for rows) that didn't add up to
  the same total — visibly misaligned left edges, caught only via a screenshot (nothing
  crashes or warns about this). Fixed by giving the root `VStack` explicit
  `alignment: .leading`, giving the search/compose field an explicit
  `.frame(maxWidth: .infinity, alignment: .leading)` so it doesn't shrink-to-fit and get
  centered, and routing every section's horizontal padding through the shared
  `PopoverLayout.horizontalInset`/`popoverSection()` (`PopoverLayout.swift`) instead of
  separate literals. This is exactly the class of bug the `MenuBarPopoverView.swift` +
  `PopoverLayout.swift` split is meant to prevent going forward.
- **A caption that relied on the root `VStack`'s old default `.center` alignment breaks
  silently when that default changes.** The "↩ switch · ⌘↩ send message" hint text (since
  removed — it's covered by Settings' Quickstart now) had no alignment of its own; once
  the root was made `.leading`, its leading "↩" character sat flush against the edge and
  got visually clipped. If you add a centered caption anywhere in the popover, give it
  its own explicit `.frame(maxWidth: .infinity, alignment: .center)` — don't lean on
  whatever the container's default happens to be.
- **`Form { }.formStyle(.grouped)` doesn't report a usable ideal height to
  `NSWindow(contentViewController:)`** — the Settings window collapsed to ~32pt tall
  (titlebar only, zero content visible) when the plain-style `Form` was switched to
  `.grouped` for the boxed-section look. The plain style had auto-sized fine. Fixed with
  an explicit `.frame(width: 460, height: 640)` on `SettingsView`'s body, tall enough
  that all four sections fit without the internal List needing to scroll at all (an
  initial guess of 480 was still too short — it just scrolled instead of collapsing,
  which is its own problem, see the next gotcha). Caught via a real screenshot showing
  just a titlebar strip, not a crash or warning.
- **`.scrollIndicators(.hidden)` does not stop a scrollbar from actually appearing** once
  content overflows under a non-overlay system scrollbar setting (`defaults read
  NSGlobalDomain AppleShowScrollBars`) — it only controls SwiftUI's newer overlay-
  indicator API, not the classic AppKit `NSScroller` that still gets attached to the
  underlying `NSScrollView` and reserves/shifts layout width. Confirmed via a real
  screenshot showing a scrollbar thumb in the "Last message" panel despite that modifier
  being applied. `ScrollbarSuppressor.swift` reaches the real `NSScrollView` (via
  `.background(ScrollbarSuppressor())` on the scrollable *content*, not the `ScrollView`)
  and sets `hasVerticalScroller`/`hasHorizontalScroller = false` directly — that's the
  authoritative fix. Any `.formStyle(.grouped)` `Form` is List-backed and has the same
  issue if its content ever overflows.
