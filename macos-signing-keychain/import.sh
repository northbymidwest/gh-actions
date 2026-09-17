#!/usr/bin/env bash
# Create a throwaway keychain and import a Developer ID certificate into it.
# Invoked by macos-signing-keychain/action.yml with CERTIFICATE/CERT_PASSWORD/
# KEYCHAIN_PATH in the env.
set -euo pipefail

[ -n "${CERTIFICATE}" ] || {
  echo "certificate is required when importing" >&2
  exit 1
}

keychain="${KEYCHAIN_PATH:-${RUNNER_TEMP}/signing.keychain-db}"
# A password nobody needs to know: the keychain lives as long as the job, and
# every command that touches it is in this file.
password=$(uuidgen)

security create-keychain -p "${password}" "${keychain}"
# Do not let it relock mid-build. The timeout is a backstop for a job that
# hangs rather than a security boundary; remove.sh is the real one.
security set-keychain-settings -lut 21600 "${keychain}"
security unlock-keychain -p "${password}" "${keychain}"

dir=$(mktemp -d)
chmod 700 "${dir}"
trap 'rm -rf "${dir}"' EXIT
printf '%s' "${CERTIFICATE}" | base64 --decode >"${dir}/cert.p12"

security import "${dir}/cert.p12" -k "${keychain}" -P "${CERT_PASSWORD}" \
  -T /usr/bin/codesign -T /usr/bin/security

# Without this, codesign blocks on a UI prompt for permission to use the key,
# which on a runner means hanging until the job times out.
security set-key-partition-list -S apple-tool:,apple: -s -k "${password}" "${keychain}" >/dev/null

# Prepend rather than replace, so the runner's own keychains stay reachable.
# The list is one quoted path per line; read it into an array rather than
# splitting an unquoted expansion, which would break on a path with a space.
# Capture on its own line so a failure stops the script rather than being
# masked by the loop it feeds.
list=$(security list-keychains -d user)
existing=()
while IFS= read -r line; do
  line="${line#*\"}"
  existing+=("${line%\"*}")
done <<<"${list}"
security list-keychains -d user -s "${keychain}" "${existing[@]}"

identity=$(security find-identity -v -p codesigning "${keychain}" |
  sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)
[ -n "${identity}" ] || {
  echo "no Developer ID Application identity in the imported certificate" >&2
  security find-identity -v -p codesigning "${keychain}" >&2
  exit 1
}

{
  printf 'keychain-path=%s\n' "${keychain}"
  printf 'identity=%s\n' "${identity}"
} >>"${GITHUB_OUTPUT}"
echo "::notice::imported ${identity}"
