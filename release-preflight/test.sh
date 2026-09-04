#!/usr/bin/env bash
# Dependency-free unit tests for release-preflight/lib.sh. Pure bash: live() is
# a fake driven by ${LIVE}, so nothing touches crates.io, gh, or git. Run it
# directly (bash release-preflight/test.sh); CI runs it in the smoke job.
set -euo pipefail
dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=release-preflight/lib.sh
. "${dir}/lib.sh"

pass=0
fail=0
check() { # description expected actual
  if [ "${2}" = "${3}" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "${1}" "${2}" "${3}" >&2
  fi
}

# Fake crates.io: ${LIVE} lists the "crate@version" pairs already published.
LIVE=""
live() {
  case " ${LIVE} " in
    *" ${1}@${2} "*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- is_valid_version ---
for v in 1.0.0 0.1.1 10.20.30; do
  if is_valid_version "${v}"; then r=ok; else r=no; fi
  check "valid: ${v}" ok "${r}"
done
for v in v1.0.0 1.0 1 "" x.y.z; do
  if is_valid_version "${v}"; then r=ok; else r=no; fi
  check "invalid: ${v}" no "${r}"
done

# --- compute_publish: nothing published (a fresh release) ---
LIVE=""
compute_publish 0.1.1 a b c
check "fresh json" '["a","b","c"]' "${PUBLISH_JSON}"
check "fresh registry" "not yet published; will publish: a b c" "${REGISTRY}"
check "fresh broke" false "${RESUME_BROKE}"
check "fresh all_live" false "${RESUME_ALL_LIVE}"

# --- resume: an already-published prefix is skipped ---
LIVE="a@0.1.1"
compute_publish 0.1.1 a b c
check "resume json" '["b","c"]' "${PUBLISH_JSON}"
check "resume registry" "RESUME: uploading only b c" "${REGISTRY}"
check "resume broke" false "${RESUME_BROKE}"
check "resume any_live" true "${RESUME_ANY_LIVE}"

# --- everything already published ---
LIVE="a@0.1.1 b@0.1.1 c@0.1.1"
compute_publish 0.1.1 a b c
check "all json" "[]" "${PUBLISH_JSON}"
check "all registry" "all already published" "${REGISTRY}"
check "all all_live" true "${RESUME_ALL_LIVE}"

# --- inconsistent: a published crate follows an unpublished one ---
LIVE="b@0.1.1"
compute_publish 0.1.1 a b c
check "broke flag" true "${RESUME_BROKE}"
check "broke json" '["a","c"]' "${PUBLISH_JSON}"

# --- version-scoped: a@0.2.0 being live must not count for 0.1.1 ---
LIVE="a@0.2.0"
compute_publish 0.1.1 a
check "version-scoped json" '["a"]' "${PUBLISH_JSON}"

# --- no packages (a tag-only repo) ---
compute_publish 0.1.1
check "empty json" "[]" "${PUBLISH_JSON}"
check "empty registry" "" "${REGISTRY}"

# --- single package already live ---
LIVE="solo@1.2.3"
compute_publish 1.2.3 solo
check "single-live json" "[]" "${PUBLISH_JSON}"
check "single-live registry" "all already published" "${REGISTRY}"

printf '\n%d passed, %d failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
