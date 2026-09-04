#!/usr/bin/env bash
# Push the protected v<version> tag with the deploy key and cut the GitHub
# release. Invoked by release-tag/action.yml with VERSION/RELEASE_TAG_KEY/
# GH_TOKEN/CHANGELOG/PRERELEASE/REPO in the env.
set -eu
sha=$(git rev-parse HEAD)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
printf '%s\n' "$RELEASE_TAG_KEY" > "$dir/key"
chmod 600 "$dir/key"
# Host keys straight from GitHub's meta API, pinned for this one push.
gh api meta --jq '.ssh_keys[] | "github.com \(.)"' > "$dir/known_hosts"
GIT_SSH_COMMAND="ssh -F /dev/null -i $dir/key -o IdentitiesOnly=yes -o IdentityAgent=none -o UserKnownHostsFile=$dir/known_hosts -o StrictHostKeyChecking=yes" \
  git push "git@github.com:$REPO.git" "$sha:refs/tags/v$VERSION"
awk -v v="$VERSION" 'index($0, "## " v " ") == 1 {f=1; next} /^## / {f=0} f' \
  "$CHANGELOG" > "$dir/notes.md"
flag=""
if [ "$PRERELEASE" = "true" ]; then flag="--prerelease"; fi
# shellcheck disable=SC2086
gh release create "v$VERSION" --title "v$VERSION" \
  --notes-file "$dir/notes.md" --verify-tag $flag
echo "::notice::tagged v$VERSION at $sha and created the release"
