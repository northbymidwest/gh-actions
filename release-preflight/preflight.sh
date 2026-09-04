#!/usr/bin/env bash
# Release preflight checks. Invoked by release-preflight/action.yml with its
# inputs in the environment; writes tag/publish/registry to ${GITHUB_OUTPUT}.
set -euo pipefail
# No globbing: the lists below are iterated by whitespace splitting, and a crate
# name or path must never be expanded as a glob.
set -f

# shellcheck source=release-preflight/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

is_valid_version "${VERSION}" || fail "version must be MAJOR.MINOR.PATCH with no leading v (got '${VERSION}')"

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
# compute_publish (lib.sh) does the pure computation; the soft/notice side
# effects, which depend on DRY, stay here.
# shellcheck disable=SC2086 # deliberate word-splitting of the packages list
compute_publish "${VERSION}" ${PACKAGES}
if [ "${RESUME_BROKE}" = true ]; then
  soft "crates.io state for ${VERSION} is inconsistent (a published crate follows an unpublished one); no release produces this, check by hand"
fi
if [ "${RESUME_ALL_LIVE}" = true ]; then
  soft "every package already has ${VERSION} published"
elif [ "${RESUME_ANY_LIVE}" = true ]; then
  [ "${DRY}" = true ] || echo "::notice::resuming a half-finished release; uploading only:${TO_PUBLISH}"
fi
{
  echo "publish=${PUBLISH_JSON}"
  echo "registry=${REGISTRY}"
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

echo "::notice::preflight passed for ${VERSION} at ${sha} (${REGISTRY})"
