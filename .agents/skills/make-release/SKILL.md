---
name: make-release
description: "Cut a new monica release end to end: bump the app version, push master, wait for CI to go green, tag the release with notes, push the tag to trigger the release workflow, and confirm the GitHub release is published. Use when asked to release a new version of monica."
user_invocable: true
---

# make-release

monica's actual build/publish step is CI-driven (`.github/workflows/release.yml`):
pushing a `v*` tag builds `monica.app`, zips it, and creates a GitHub release. This
skill is the runbook + script for everything around that trigger — the parts CI can't
do for you (deciding the version number, writing the notes, gating on green CI).

## Usage

Write release notes first (markdown, this becomes the release body verbatim):

```sh
$EDITOR /tmp/notes.md
```

Then run:

```sh
.agents/skills/make-release/release.sh 1.0.2 /tmp/notes.md
```

This does, in order:

1. Bumps `CFBundleShortVersionString` in `build-app.sh` to the given version.
2. Creates a jj commit ("Bump version to X.Y.Z for release"), moves the `master`
   bookmark to it, and pushes.
3. Watches the `CI` workflow run on `master` and **stops if it fails** — a red release
   commit never gets tagged.
4. Creates an **annotated** git tag `vX.Y.Z` (message = your notes file) directly against
   the underlying git store (`jj git root`), since jj bookmarks/tags don't carry
   annotation text — see "Why an annotated tag" below.
5. Pushes the tag, which triggers `release.yml`.
6. Watches the `Release` workflow run and prints the release URL once it's done.

Open the printed URL (or `gh release view vX.Y.Z --repo meain/monica`) afterward and
confirm the notes and asset look right — the script doesn't do that for you.

## Why an annotated tag, and the checkout gotcha

`release.yml` calls `gh release create ... --notes-from-tag`, which reads the
**annotated tag's message** (falling back to the tagged commit's message for a
lightweight tag). jj's own `jj tag set` only creates lightweight tags with no message,
so the tag has to be created with plain `git tag -a -F <notes>` against jj's internal
git store (`jj git root` — this repo isn't git-colocated, there's no top-level `.git`).

The first real release cut this way (v1.0.1) shipped with the *wrong* body — the tagged
commit's message instead of the curated notes — because `actions/checkout@v4`'s default
shallow fetch grabs the tagged commit but not the annotated tag object, so
`--notes-from-tag` silently fell back. `release.yml` now has an explicit
`git fetch origin refs/tags/$TAG --force` step before the release step to fix this.
Don't remove that step, and if `--notes-from-tag` ever looks wrong again in a future
release, check that step first before suspecting the tag itself — verify what GitHub
actually stored with:

```sh
gh api repos/meain/monica/git/refs/tags/vX.Y.Z --jq .object.sha
gh api repos/meain/monica/git/tags/<that-sha>
```

If that API response has the right message but the release still doesn't, it's the
workflow's checkout, not the tag.

## Fixing a botched release after the fact

If a release publishes with the wrong notes (like v1.0.1 initially did), no need to
delete/retag — just edit it in place:

```sh
gh release edit vX.Y.Z --repo meain/monica --notes-file /tmp/notes.md --title vX.Y.Z
```

## Non-obvious things

- The script hard-requires `X.Y.Z` version format and fails fast if the `sed` bump
  didn't actually change `build-app.sh` (e.g. the plist key text changed).
- It aborts on the *first* red CI run rather than retrying — investigate and fix on
  `master` normally, then re-run this script (it's safe to re-run; the version bump step
  will just no-op if already at that version, though describing on top of an unrelated
  commit needs a clean working copy).
- Uses `gh run watch --exit-status`, so a failing CI or release workflow makes the whole
  script exit non-zero — treat that as "release did not go out," not "release went out
  broken."
