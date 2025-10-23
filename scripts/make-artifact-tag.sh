#!/usr/bin/env bash
#
# After tagging a release (say, v1.2.3), use this script to publish
# lua/morph.lua in an artifact branch: artifact-v1.2.3:init.lua. To do so,
# invoke the script from the root of the repo like so:
#
# ./scripts/make-artifact-tag.sh v1.2.3
#
# This will create a temporary orphan branch, tag it and immediately delete the
# branch.
#
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: ./mkartifact.sh <TAG>"
  exit 1
fi

TAG="$1"
if [[ "$(echo "$TAG" | awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/ { print "YES" }')" != "YES" ]]; then # +\.\d+\.\d+$
  echo "Invalid tag name: expected 'artifact-vX.Y.Z'"
  exit 1
fi

ARTIFACT_TAG="artifact-$TAG"
EXISTING_ARTIFACT_TAG=$(git tag -l "$ARTIFACT_TAG")

if [[ "$ARTIFACT_TAG" = "$EXISTING_ARTIFACT_TAG" ]]; then
  echo "Artifact tag already exists"
  exit 1
fi

git worktree add --orphan -b "$ARTIFACT_TAG" "$ARTIFACT_TAG"
git cat-file -p "$TAG":lua/morph.lua > "$ARTIFACT_TAG"/init.lua

pushd "$ARTIFACT_TAG"
git add --all
git commit --message "$ARTIFACT_TAG"
git tag "$ARTIFACT_TAG"
popd

git worktree remove -f "$ARTIFACT_TAG"
git branch -D "$ARTIFACT_TAG"
