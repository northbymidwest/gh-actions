#!/usr/bin/env bash
# Pure, side-effect-free helpers for release-preflight, split out so they can be
# unit-tested (see test.sh) without touching crates.io, gh, or git. Sourced by
# preflight.sh; nothing here reads the environment or exits.

# compute_publish sets several variables read by the sourcing script, so they
# look unused when this file is linted on its own.
# shellcheck disable=SC2034

# A release version is MAJOR.MINOR.PATCH with no leading v. Returns 0/1.
is_valid_version() {
  case "$1" in
    v*) return 1 ;;
    [0-9]*.[0-9]*.[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# Decide which of the packages still need publishing, given their crates.io
# state. Probes each with `live <crate> <version>` (0 = already published), which
# the caller provides (the real one curls; the tests inject a fake). Arguments:
# the version, then the packages in publish order.
#
# Sets, in the caller's scope:
#   PUBLISH_JSON     JSON array of packages still to upload ([] if none)
#   REGISTRY         one-line human summary
#   TO_PUBLISH       space-prefixed list of packages still to upload
#   RESUME_ANY_LIVE  true if any package is already published
#   RESUME_ALL_LIVE  true if every package is already published
#   RESUME_BROKE     true if a published package follows an unpublished one
#                    (a state no release can produce: the caller treats it as
#                    fatal outside a dry run)
compute_publish() {
  local ver=$1
  shift
  PUBLISH_JSON="[]"
  REGISTRY=""
  TO_PUBLISH=""
  RESUME_ANY_LIVE=false
  RESUME_ALL_LIVE=false
  RESUME_BROKE=false
  [ "$#" -gt 0 ] || return 0

  local any_live=false all_live=true prev_live=true broke=false c sep
  for c in "$@"; do
    if live "${c}" "${ver}"; then
      [ "${prev_live}" = true ] || broke=true
      any_live=true
    else
      prev_live=false
      all_live=false
      TO_PUBLISH="${TO_PUBLISH} ${c}"
    fi
  done

  # Build the JSON array by hand (crate names are [a-z0-9._-], no escaping) so
  # there is no pipe whose upstream failure could be masked.
  PUBLISH_JSON="["
  sep=""
  for c in ${TO_PUBLISH}; do
    PUBLISH_JSON="${PUBLISH_JSON}${sep}\"${c}\""
    sep=","
  done
  PUBLISH_JSON="${PUBLISH_JSON}]"

  RESUME_ANY_LIVE=${any_live}
  RESUME_ALL_LIVE=${all_live}
  RESUME_BROKE=${broke}
  if [ "${all_live}" = true ]; then
    REGISTRY="all already published"
  elif [ "${any_live}" = true ]; then
    REGISTRY="RESUME: uploading only${TO_PUBLISH}"
  else
    REGISTRY="not yet published; will publish:${TO_PUBLISH}"
  fi
}
