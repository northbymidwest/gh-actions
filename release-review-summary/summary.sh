#!/usr/bin/env bash
# Write the approver's review table to $GITHUB_STEP_SUMMARY. Invoked by
# release-review-summary/action.yml with its inputs in the env.
set -eu
sha=$(git rev-parse HEAD)
subject=$(git log -1 --format=%s)
ci=$(gh api "repos/$REPO/actions/runs?head_sha=$sha&status=completed" \
  | jq -r --arg w "$CI_WORKFLOW" '[.workflow_runs[] | select(.name == $w)] | sort_by(.created_at) | last | .id // empty')
awk -v v="$VERSION" 'index($0, "## " v " ") == 1 {f=1; next} /^## / {f=0} f' \
  "$CHANGELOG" > /tmp/review-notes.md
{
  if [ "$DRY" = true ]; then
    echo "## Dry run: \`$VERSION\` (nothing will be published or tagged)"
  else
    echo "## Release \`$VERSION\`: approving $DOES"
  fi
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| version | \`$VERSION\` |"
  echo "| commit | \`$sha\` $subject |"
  if [ -n "$ci" ]; then
    echo "| CI | [green on this commit]($RUNS/$ci) |"
  else
    echo "| CI | (no run found) |"
  fi
  [ -n "$TAG" ] && echo "| tag | \`v$VERSION\`: $TAG |"
  [ -n "$REGISTRY" ] && echo "| registry | $REGISTRY |"
  # Extra rows: 'label|value' per line.
  printf '%s\n' "$EXTRA" | while IFS='|' read -r label value; do
    [ -n "$label" ] || continue
    echo "| $label | $value |"
  done
  if [ "$DRY" = true ]; then
    echo
    echo "A taken tag or a published version is reported, not fatal, on a dry run; a real run stops at either."
  fi
  echo
  echo "### Release notes, verbatim from \`$CHANGELOG\`"
  echo
  cat /tmp/review-notes.md
} >> "$GITHUB_STEP_SUMMARY"
