#!/usr/bin/env bash
# Build and optionally sign a distributable disk image. Invoked by
# macos-dmg/action.yml with APP/OUTPUT/VOLUME_NAME/IDENTITY in the env.
set -euo pipefail

[ -d "${APP}" ] || {
  echo "no such app bundle: ${APP}" >&2
  exit 1
}

name=$(basename "${APP}" .app)
volume="${VOLUME_NAME:-${name}}"

# Stage the contents rather than pointing hdiutil at the .app directly: the
# image should hold the application and the drop target, and a staging
# directory is the only way to say exactly that.
stage=$(mktemp -d)
trap 'rm -rf "${stage}"' EXIT
cp -R "${APP}" "${stage}/"
ln -s /Applications "${stage}/Applications"

# The icon positions and window size live in a .DS_Store at the volume root.
# Finder writes one when somebody arranges the window by hand or by
# AppleScript, and neither is available on a runner, so the consumer generates
# it once and commits it. Copied in under its real name here, since it is
# almost certainly stored under another one to get past a .gitignore.
if [ -n "${DS_STORE:-}" ]; then
  [ -f "${DS_STORE}" ] || {
    echo "no such .DS_Store: ${DS_STORE}" >&2
    exit 1
  }
  cp "${DS_STORE}" "${stage}/.DS_Store"
fi

rm -f "${OUTPUT}"
# UDZO is the compressed read-only format every macOS since forever mounts
# without a third-party tool. -quiet because hdiutil's progress is noise in a
# log nobody reads unless it failed.
hdiutil create -quiet -volname "${volume}" -srcfolder "${stage}" \
  -ov -format UDZO "${OUTPUT}"

if [ -n "${IDENTITY}" ]; then
  # A disk image is code to Gatekeeper, and the notary service rejects an
  # unsigned one. No --options runtime here: the hardened runtime applies to
  # the executable inside, which was signed with it when the app was built.
  codesign --sign "${IDENTITY}" --timestamp --force "${OUTPUT}"
  codesign --verify --verbose=2 "${OUTPUT}"
else
  echo "::warning::built ${OUTPUT} unsigned; it cannot be notarized or distributed"
fi

digest=$(shasum -a 256 "${OUTPUT}" | cut -d' ' -f1)
{
  printf 'path=%s\n' "${OUTPUT}"
  printf 'sha256=%s\n' "${digest}"
} >>"${GITHUB_OUTPUT}"
echo "::notice::built ${OUTPUT} (${digest})"
