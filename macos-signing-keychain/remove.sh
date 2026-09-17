#!/usr/bin/env bash
# Delete the throwaway signing keychain. Invoked by
# macos-signing-keychain/action.yml with KEYCHAIN_PATH in the env.
#
# Deliberately quiet when there is nothing to remove: this runs behind
# if: always(), including on a job that failed before the import.
set -euo pipefail

keychain="${KEYCHAIN_PATH:-${RUNNER_TEMP}/signing.keychain-db}"
if [ -f "${keychain}" ]; then
  security delete-keychain "${keychain}"
  echo "::notice::removed ${keychain}"
fi
