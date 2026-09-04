#!/usr/bin/env bash
# The dry-run branch of release-tag: tag nothing, report what a real run would
# do. Invoked by release-tag/action.yml with VERSION in the env.
set -eu
echo "Dry run only. A real run would tag \`v$VERSION\` at $(git rev-parse HEAD), permanently, and cut the GitHub release from the CHANGELOG section." >> "$GITHUB_STEP_SUMMARY"
echo "::notice::dry run complete: nothing tagged"
