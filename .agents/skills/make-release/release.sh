#!/usr/bin/env bash
# Cuts a CI-built monica release: bumps the app version, pushes master, waits
# for CI to go green, tags the release (with notes), pushes the tag, and
# waits for the release workflow to publish it. See SKILL.md for the full
# writeup of why each step exists.
set -euo pipefail

cd "$(dirname "$0")/../../.."

if [ $# -ne 2 ]; then
  echo "usage: release.sh <version e.g. 1.0.2> <notes-file>" >&2
  exit 1
fi

VERSION="$1"
NOTES_FILE="$2"
TAG="v${VERSION}"
REPO="meain/monica"

[ -f "$NOTES_FILE" ] || { echo "notes file not found: $NOTES_FILE" >&2; exit 1; }
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version must look like 1.2.3, got: $VERSION" >&2
  exit 1
fi

GITDIR="$(jj git root)"

echo "==> Bumping CFBundleShortVersionString to $VERSION"
sed -i '' -E "s/(CFBundleShortVersionString<\/key> <string>)[0-9]+\.[0-9]+\.[0-9]+/\1${VERSION}/" build-app.sh
grep -q "<string>${VERSION}</string>" build-app.sh || {
  echo "version bump didn't take — check build-app.sh's plist key by hand" >&2
  exit 1
}

jj describe -m "Bump version to ${VERSION} for release"
COMMIT="$(jj log -r @ --no-graph -T 'commit_id.short()')"
jj bookmark set master -r "$COMMIT"
jj new

echo "==> Pushing master ($COMMIT)"
jj git push --bookmark master

echo "==> Waiting for CI on master"
sleep 5 # give GitHub a moment to register the push before we list runs
RUN_ID="$(gh run list --repo "$REPO" --branch master --workflow CI --limit 1 --json databaseId -q '.[0].databaseId')"
gh run watch "$RUN_ID" --repo "$REPO" --exit-status

echo "==> CI green. Tagging $TAG"
git --git-dir="$GITDIR" tag -a "$TAG" -F "$NOTES_FILE" "$COMMIT"
git --git-dir="$GITDIR" push origin "refs/tags/$TAG"

echo "==> Waiting for release workflow"
sleep 5
RELEASE_RUN_ID="$(gh run list --repo "$REPO" --branch "$TAG" --workflow Release --limit 1 --json databaseId -q '.[0].databaseId')"
gh run watch "$RELEASE_RUN_ID" --repo "$REPO" --exit-status

echo "==> Published: https://github.com/${REPO}/releases/tag/${TAG}"
echo "    Review the notes with: gh release view ${TAG} --repo ${REPO}"
