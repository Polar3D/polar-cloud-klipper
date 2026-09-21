#!/bin/sh
# Tag and publish a GitHub release from main.
#
# Run after the release is merged to main, with a "## [X.Y.Z] - date" section
# in CHANGELOG.md. That section becomes the release notes. Nothing is
# committed; the script only creates and pushes the tag and the release.
#
# Why the GitHub release matters: the agent's update check and
# install_embedded.sh both use the "latest release", not just the tag, and
# Moonraker's update manager (channel = stable) follows tags on main.
#
# Usage: scripts/release.sh 1.6.0 "Short summary for the release title"
#        scripts/release.sh 1.6.0 "Short summary" --dry-run

set -e

VERSION="${1#v}"
SUMMARY="$2"
DRY_RUN="$3"

if [ -z "$VERSION" ] || [ -z "$SUMMARY" ]; then
    echo "Usage: $0 <version> \"<summary>\" [--dry-run]" >&2
    exit 1
fi
TAG="v$VERSION"

cd "$(dirname "$0")/.."

command -v gh >/dev/null 2>&1 || { echo "gh (GitHub CLI) is required" >&2; exit 1; }

git fetch --quiet --tags origin main

if [ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]; then
    echo "HEAD is not origin/main. Check out main and pull first." >&2
    exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Working tree has uncommitted changes." >&2
    exit 1
fi
if git rev-parse --quiet --verify "refs/tags/$TAG" >/dev/null; then
    echo "Tag $TAG already exists." >&2
    exit 1
fi

# Release notes: the CHANGELOG section for this version, without its heading
NOTES=$(awk -v v="$VERSION" '
    index($0, "## [" v "]") == 1 { found = 1; next }
    found && /^## \[/ { exit }
    found { print }
' CHANGELOG.md)
if [ -z "$(printf '%s' "$NOTES" | tr -d '[:space:]')" ]; then
    echo "CHANGELOG.md has no \"## [$VERSION]\" section (or it is empty)." >&2
    echo "Rename \"## [Unreleased]\" to \"## [$VERSION] - $(date +%Y-%m-%d)\" and merge that first." >&2
    exit 1
fi

TITLE="$TAG - $SUMMARY"
echo "Release: $TITLE"
echo "Commit:  $(git log --oneline -1)"
echo "Notes:"
printf '%s\n' "$NOTES" | sed 's/^/  /'

if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "Dry run: nothing tagged or published."
    exit 0
fi

printf 'Create and push %s and publish the release? [y/N] ' "$TAG"
read -r answer
[ "$answer" = "y" ] || [ "$answer" = "Y" ] || { echo "Aborted."; exit 1; }

git tag -a "$TAG" -m "$TITLE"
git push origin "$TAG"
printf '%s\n' "$NOTES" | gh release create "$TAG" --verify-tag --title "$TITLE" --notes-file -

echo "Published $TAG"
