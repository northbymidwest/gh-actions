#!/usr/bin/env bash
# Release preflight checks. Invoked by release-preflight/action.yml with its
# inputs in the environment; writes tag/publish/registry to ${GITHUB_OUTPUT}.
set -euo pipefail
# No globbing: the lists below are iterated by whitespace splitting, and a crate
# name or path must never be expanded as a glob.
set -f

fail() {
  echo "::error::$1"
  exit 1
}
# A dry run is meant to be usable on a version that already shipped, the only
# way to exercise this before trusting it. The checks a rehearsal is allowed to
# trip warn instead of stopping; everything else still stops.
soft() {
  if [ "${DRY}" = "true" ]; then echo "::warning::(dry run) $1"; else fail "$1"; fi
}
ua='northbymidwest-release-workflow'

# crates.io says whether <crate>/<version> exists: live 0, absent 1, anything
# else fatal (a publish is irreversible; guessing is worse than stopping).
live() {
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -H "User-Agent: ${ua}" \
    "https://crates.io/api/v1/crates/$1/$2")
  case "${code}" in
    404) return 1 ;;
    200) return 0 ;;
    *) fail "crates.io answered HTTP ${code} for $1 $2; cannot tell whether it is published" ;;
  esac
}

case "${VERSION}" in
  v*) fail "version must not start with v" ;;
  [0-9]*.[0-9]*.[0-9]*) : ;;
  *) fail "version must look like MAJOR.MINOR.PATCH" ;;
esac

# Every listed manifest must carry this version and must no longer be
# publish = false. Read them rather than trust them. (awk stops at the first
# match, so its exit status is not masked by a pipe.)
# shellcheck disable=SC2086 # deliberate word-splitting of the manifest list
for man in ${CRATES}; do
  [ -f "${man}" ] || fail "${man} does not exist"
  v=$(awk -F'"' '/^version = "[0-9.]*"$/ { print $2; exit }' "${man}")
  [ "${v}" = "${VERSION}" ] || fail "${man} says version ${v}, expected ${VERSION}"
  if grep -q '^publish = false' "${man}"; then
    soft "${man} is still publish = false; remove it to release"
  fi
done

# Exact-version pins: a manifest that pins a sibling '=<version>' must actually
# pin this version, so a lockstep bump cannot miss one.
# shellcheck disable=SC2086 # deliberate word-splitting of the pins list
for spec in ${PINS}; do
  man=${spec%%|*}
  rest=${spec#*|}
  dep=${rest%%|*}
  want=${rest#*|}
  [ -n "${want}" ] || want=${VERSION}
  [ -f "${man}" ] || fail "${man} does not exist (pin check for ${dep})"
  got=$(sed -n "/${dep} = { version = \"=/ { s/.*version = \"=\([^\"]*\)\".*/\1/p; q; }" "${man}")
  [ "${got}" = "${want}" ] || fail "${man} pins ${dep} =${got}, expected =${want}"
done

# Cross-repo prerequisites: hl needs gputrace-bundle, ktx2 needs hl, and each
# resolves it from the registry at publish time, so the required version must
# already be live. This is the publish-first ordering.
# shellcheck disable=SC2086 # deliberate word-splitting of the prereqs list
for pair in ${PREREQS}; do
  crate=${pair%%=*}
  man=${pair#*=}
  [ -f "${man}" ] || fail "${man} does not exist (prereq for ${crate})"
  req=$(sed -n "/^${crate} = / { s/.*version = \"\([^\"]*\)\".*/\1/p; q; }" "${man}")
  [ -n "${req}" ] || fail "could not read the required version of ${crate} from ${man}"
  if live "${crate}" "${req}"; then
    echo "::notice::prerequisite ${crate} ${req} is live on crates.io"
  else
    soft "${crate} ${req} is not published; release it from its own repo first"
  fi
done

# The tag must not already exist: a protected tag cannot be moved.
if git ls-remote --exit-code --tags origin "refs/tags/v${VERSION}" >/dev/null 2>&1; then
  soft "tag v${VERSION} already exists, and protected tags cannot be moved"
  echo "tag=exists" >>"${GITHUB_OUTPUT}"
else
  echo "tag=free" >>"${GITHUB_OUTPUT}"
fi

# crates.io state for the packages being released. None may already be live,
# with one exception: a release that died partway leaves a prefix of the publish
# order live and no tag. Rather than burn a version for a propagation hiccup,
# the already-live prefix is skipped and the run resumes at the first not-live
# package. Any live package after a not-live one is a state no release can
# produce, and stays fatal.
publish_json="[]"
registry=""
if [ -n "${PACKAGES//[[:space:]]/}" ]; then
  to_publish=""
  any_live=false
  all_live=true
  prev_live=true
  broke=false
  # shellcheck disable=SC2086 # deliberate word-splitting of the packages list
  for c in ${PACKAGES}; do
    if live "${c}" "${VERSION}"; then
      [ "${prev_live}" = true ] || broke=true
      any_live=true
    else
      prev_live=false
      all_live=false
      to_publish="${to_publish} ${c}"
    fi
  done
  # Build the JSON array by hand (crate names are [a-z0-9._-], no escaping) so
  # there is no pipe whose upstream failure could be masked.
  publish_json="["
  sep=""
  # shellcheck disable=SC2086 # deliberate word-splitting of the to-publish list
  for c in ${to_publish}; do
    publish_json="${publish_json}${sep}\"${c}\""
    sep=","
  done
  publish_json="${publish_json}]"
  if [ "${broke}" = true ]; then
    soft "crates.io state for ${VERSION} is inconsistent (a published crate follows an unpublished one); no release produces this, check by hand"
  fi
  if [ "${all_live}" = true ]; then
    soft "every package already has ${VERSION} published"
    registry="all already published"
  elif [ "${any_live}" = true ]; then
    [ "${DRY}" = true ] || echo "::notice::resuming a half-finished release; uploading only:${to_publish}"
    registry="RESUME: uploading only${to_publish}"
  else
    registry="not yet published; will publish:${to_publish}"
  fi
fi
{
  echo "publish=${publish_json}"
  echo "registry=${registry}"
} >>"${GITHUB_OUTPUT}"

# A changelog section for this version must exist and be non-empty.
[ -f "${CHANGELOG}" ] || fail "${CHANGELOG} does not exist"
awk -v v="${VERSION}" 'index($0, "## " v " ") == 1 { f = 1; next } /^## / { f = 0 } f' \
  "${CHANGELOG}" >/tmp/preflight-notes.md
grep -q '[^[:space:]]' /tmp/preflight-notes.md || fail "${CHANGELOG} has no ## ${VERSION} section"

# The newest completed run of the CI workflow for this commit must be green.
# Queried rather than re-run. gh runs on its own line so its failure is caught
# by set -e rather than masked by the jq that consumes it.
sha=$(git rev-parse HEAD)
runs_json=$(gh api "repos/${REPO}/actions/runs?head_sha=${sha}&status=completed")
concl=$(jq -r --arg w "${CI_WORKFLOW}" \
  '[.workflow_runs[] | select(.name == $w)] | sort_by(.created_at) | last | .conclusion // "none"' \
  <<<"${runs_json}")
[ "${concl}" = "success" ] || soft "newest ${CI_WORKFLOW} run for ${sha} is '${concl}', not success"

echo "::notice::preflight passed for ${VERSION} at ${sha} (${registry})"
