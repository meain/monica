---
name: update-readme-screenshot
description: "Refresh the popover screenshot embedded in README.md by running a real Claude Code session against a disposable demo project, rendering monica's popover with that session selected, and uploading the result via `gh image` (no PNG committed to the repo). Use when the popover UI has changed visually and the README screenshot is stale."
user_invocable: true
---

# update-readme-screenshot

Regenerates the README's popover screenshot end to end, without touching any of your
real tmux sessions or their transcripts, and without adding a binary to the repo:

1. Creates a throwaway project at `/tmp/demo-app` (a two-line `main.go` + `README.md`).
2. Starts a **new** tmux session (`monica-demo`) and launches a real `claude` there —
   real integration, not fabricated transcript/aistatus files (their exact shapes are
   finicky enough that faking them isn't worth it — see AGENTS.md's transcript-format
   gotchas).
3. Drives one short, clean prompt designed to produce a nicely structured reply (a
   heading + a few bullet points) — good screenshot content, no real work content.
4. Waits for that session to go idle (polls its `aistatus` pid file).
5. Builds monica's debug binary and renders the popover via the `MONICA_SHOT` hook
   (see the sibling `screenshot-test` skill and AGENTS.md's "Verifying the GUI"
   section) — no Screen Recording permission needed.
6. Filters the popover to the demo agent by typing `demo-app` into the search field
   (robust regardless of how many *real* agents are running — no row-counting).
7. Uploads the render via `gh image` (produces a `github.com/user-attachments/assets/…`
   URL), posts it as a comment on the [meain/monica#4 "Media"](https://github.com/meain/monica/issues/4)
   tracking issue for a durable record, and rewrites README.md's
   `![Monica popover](...)` line to point at the new URL.
8. Cleans up: kills the `monica-demo` tmux session, deletes `/tmp/demo-app`, deletes
   the demo session's `aistatus` pid file.

## Usage

```sh
.agents/skills/update-readme-screenshot/run.sh
```

Prints the new `user-attachments` URL on success. **Open it (or check the README diff)
afterward** to confirm it looks right before considering the refresh done — the script
already rewrites `README.md` in place (`jj status`/`git status` will show it modified),
it doesn't commit anything.

## Why upload instead of committing a PNG

Committing screenshots directly balloons repo size over every refresh. Instead images
are uploaded to GitHub's `user-attachments` CDN via the `gh image` extension
(`gh extension install drogers0/gh-image`, authenticates via your browser's
`user_session` cookie — no PAT scopes needed) and also posted to the
[Media issue](https://github.com/meain/monica/issues/4) so there's a durable,
browsable history of every version. Use the same pattern (`gh image <file> --repo
meain/monica`, then `gh issue comment 4 --repo meain/monica`) for any other image
referenced from README.md or docs.md — never add a binary image to a commit here.

## Why a disposable project, not the real running agents

The popover shows real, live tmux/aistatus data with no demo-data seam (unlike
booker's `BOOKER_BM_FILE`) — pointing `MONICA_SHOT` at your actual sessions puts
whatever you're actually working on into a file that ends up in the public README.
Early manual runs of this same technique surfaced this by accident (a captured
screenshot showed the very conversation used to drive the test). A dedicated demo
project sidesteps that entirely.

## Knobs / troubleshooting

- If the script times out waiting for the demo session to go idle, `claude` may be
  slower than usual to respond (model load, network) — rerun, or bump the timeouts
  inside `run.sh`.
- If Enter doesn't submit the prompt (occasionally the keystroke lands before the
  textarea commits it), the script sends a follow-up Enter automatically; if the
  screenshot still comes out at the "Try ..." placeholder rather than a real
  agent turn, rerun.
- The script always kills any pre-existing `monica-demo` tmux session before starting
  and removes `/tmp/demo-app` first — safe unless you happen to have your own
  unrelated session with that exact name.
- Uses `env -u SDKROOT -u DEVELOPER_DIR swift build` per AGENTS.md's SDKROOT gotcha.

See the sibling `screenshot-test` skill for ad-hoc popover/menu-bar rendering that
isn't specifically about refreshing the README.
