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

# Manifests whose version must match, with nothing said about publishing. For a
# repository that ships something other than a crate, where publish = false is
# the permanent and correct state rather than a bump somebody forgot.
# shellcheck disable=SC2086 # deliberate word-splitting of the manifest list
for man in ${MANIFESTS}; do
  [ -f "${man}" ] || fail "${man} does not exist"
  v=$(awk -F'"' '/^version = "[0-9.]*"$/ { print $2; exit }' "${man}")
  [ "${v}" = "${VERSION}" ] || fail "${man} says version ${v}, expected ${VERSION}"
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

# A draft release holds its tag name without creating the tag, so the check
# above cannot see one. A consumer that creates drafts for review wants a
# second run refused rather than a second draft for the same version.
if [ "${REFUSE_EXISTING_RELEASE}" = "true" ]; then
  if gh release view "v${VERSION}" >/dev/null 2>&1; then
    soft "a release for v${VERSION} already exists, possibly as a draft; delete it to rebuild this version"
  fi
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

# The newest run of the CI workflow for this commit must be green. Queried
# rather than re-run. A release is usually dispatched right after the version
# bump lands, so that run is often still queued or in progress, or not even
# scheduled yet: poll until it completes (up to CI_WAIT_MINUTES, every
# CI_POLL_SECONDS) instead of failing on the race. A workflow that never runs
# for this commit (for example, skipped by a paths filter) waits out the whole
# window and then fails; set ci-wait-minutes to 0 to check once and not wait.
# gh runs on its own line so its failure is caught by set -e rather than masked
# by the jq that consumes it.
for n in "${CI_WAIT_MINUTES}" "${CI_POLL_SECONDS}"; do
  case "${n}" in
    '' | *[!0-9]*) fail "ci-wait-minutes and ci-poll-seconds must be whole numbers (got '${CI_WAIT_MINUTES}' and '${CI_POLL_SECONDS}')" ;;
    *) ;;
  esac
done
[ "${CI_POLL_SECONDS}" -gt 0 ] || fail "ci-poll-seconds must be at least 1"
sha=$(git rev-parse HEAD)
deadline=$(($(date +%s) + CI_WAIT_MINUTES * 60))
while :; do
  runs_json=$(gh api "repos/${REPO}/actions/runs?head_sha=${sha}")
  state=$(jq -r --arg w "${CI_WORKFLOW}" \
    '[.workflow_runs[] | select(.name == $w)] | sort_by(.created_at) | last | "\(.status // "none") \(.conclusion // "none")"' \
    <<<"${runs_json}")
  status=${state%% *}
  concl=${state#* }
  verdict=$(ci_verdict "${status}" "${concl}")
  now=$(date +%s)
  if [ "${verdict}" != wait ] || [ "${now}" -ge "${deadline}" ]; then break; fi
  echo "${CI_WORKFLOW} run for ${sha} is '${status}'; checking again in ${CI_POLL_SECONDS}s"
  sleep "${CI_POLL_SECONDS}"
done
case "${verdict}" in
  green) echo "::notice::${CI_WORKFLOW} run for ${sha} is green" ;;
  wait) soft "no completed ${CI_WORKFLOW} run for ${sha} after waiting ${CI_WAIT_MINUTES} minutes (last seen: '${status}')" ;;
  *) soft "newest ${CI_WORKFLOW} run for ${sha} is '${concl}', not success" ;;
esac

echo "::notice::preflight passed for ${VERSION} at ${sha} (${REGISTRY})"
