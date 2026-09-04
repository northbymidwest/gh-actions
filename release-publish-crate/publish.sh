#!/usr/bin/env bash
# Publish each package not already live. Invoked by release-publish-crate/
# action.yml with CARGO_REGISTRY_TOKEN plus PACKAGES/PUBLISH/ARGS in the env.
set -eu
set -f
for c in $PACKAGES; do
  if printf '%s' "$PUBLISH" | jq -e --arg c "$c" 'index($c) != null' >/dev/null; then
    echo "::notice::publishing $c"
    # ARGS is intentionally word-split (e.g. --no-default-features).
    # shellcheck disable=SC2086
    cargo publish -p "$c" $ARGS
  else
    echo "::notice::skipping $c (already on crates.io)"
  fi
done
