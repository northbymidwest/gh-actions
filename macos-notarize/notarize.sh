#!/usr/bin/env bash
# Submit, wait, staple and verify. Invoked by macos-notarize/action.yml with
# ARTIFACT/NOTARY_*/DRY_RUN in the env.
set -euo pipefail

[ -e "${ARTIFACT}" ] || {
  echo "no such artifact: ${ARTIFACT}" >&2
  exit 1
}

# Fail here rather than several minutes later with a less obvious message from
# Apple. An ad-hoc signature has no team behind it and can never notarize, and
# the hardened runtime is not optional for an executable.
siginfo=$(codesign -dv --verbose=4 "${ARTIFACT}" 2>&1)
if printf '%s' "${siginfo}" | grep -q '^Signature=adhoc'; then
  echo "${ARTIFACT} is ad-hoc signed and cannot be notarized" >&2
  exit 1
fi
case "${ARTIFACT}" in
  *.app)
    if ! printf '%s' "${siginfo}" | grep -q 'flags=.*runtime'; then
      echo "${ARTIFACT} is not signed with the hardened runtime" >&2
      exit 1
    fi
    ;;
  *) ;;
esac

auth=()
if [ -n "${NOTARY_KEY_P8}" ]; then
  : "${NOTARY_KEY_ID:?a key was given, so key-id must be too}"
  : "${NOTARY_ISSUER_ID:?a key was given, so issuer must be too}"
  dir=$(mktemp -d)
  chmod 700 "${dir}"
  trap 'rm -rf "${dir}"' EXIT
  printf '%s' "${NOTARY_KEY_P8}" >"${dir}/key.p8"
  auth=(--key "${dir}/key.p8" --key-id "${NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER_ID}")
elif [ -n "${NOTARY_PROFILE}" ]; then
  auth=(--keychain-profile "${NOTARY_PROFILE}")
else
  echo "no credentials: set key, key-id and issuer, or keychain-profile" >&2
  exit 1
fi

if ! xcrun notarytool history "${auth[@]}" >/dev/null 2>&1; then
  echo "the notary credentials were rejected" >&2
  exit 1
fi

if [ "${DRY_RUN}" = "true" ]; then
  echo "::notice::dry run: ${ARTIFACT} is signed and the credentials work; not submitting"
  exit 0
fi

# notarytool does not take a bundle, so a .app is zipped for the submission
# only. ditto rather than zip, to preserve the signature and the extended
# attributes the way Apple's own tooling expects.
submission="${ARTIFACT}"
case "${ARTIFACT}" in
  *.app)
    submission="${ARTIFACT%.app}-notarize.zip"
    rm -f "${submission}"
    /usr/bin/ditto -c -k --keepParent "${ARTIFACT}" "${submission}"
    ;;
  *) ;;
esac

xcrun notarytool submit "${submission}" "${auth[@]}" --wait

# Staple the bundle or image itself, never the zip: a zip cannot carry a
# ticket, and the zip was only ever a transport for the submission.
xcrun stapler staple "${ARTIFACT}"
case "${ARTIFACT}" in
  *.app) rm -f "${submission}" ;;
  *) ;;
esac

xcrun stapler validate "${ARTIFACT}"

# Gatekeeper asks a different question of each kind of artifact. An
# application is assessed as something to execute; a disk image is assessed as
# something to open, and needs the primary-signature context or spctl reports
# on the wrong thing.
case "${ARTIFACT}" in
  *.dmg) spctl -a -vv -t open --context context:primary-signature "${ARTIFACT}" ;;
  *) spctl -a -vv -t exec "${ARTIFACT}" ;;
esac
echo "::notice::notarized and stapled ${ARTIFACT}"
