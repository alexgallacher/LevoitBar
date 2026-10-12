#!/bin/bash
# Publishes a new LevoitBar version as a GitHub release.
#   ./release.sh 1.1.0
# Builds the app with that version, tags the current commit and uploads
# LevoitBar.zip. Installed copies update themselves on their next check.
# Needs the GitHub CLI (`gh`) signed in to an account that can push to the repo.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?Usage: ./release.sh <version>, e.g. ./release.sh 1.1.0}"
VERSION="${VERSION#v}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Commit or stash your changes first." >&2
  exit 1
fi

VERSION="$VERSION" ./build-app.sh

git tag "v$VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" build/LevoitBar.zip --title "LevoitBar $VERSION" --generate-notes

echo "Released LevoitBar $VERSION"
