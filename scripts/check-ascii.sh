#!/bin/sh
# Every tracked text file must be pure ASCII.
#
# No em dashes, en dashes, ellipses, arrows, or other typographic characters:
# each has an ASCII spelling that reads as well (`-` or a comma for a dash,
# `...`, `->`, `x`, `us`), and mixing the two is worse than either.
#
#   scripts/check-ascii.sh              # every tracked file
#   scripts/check-ascii.sh FILE...      # just these
#
# LC_ALL=C makes grep match bytes rather than characters, so every byte of a
# UTF-8 sequence falls outside printable ASCII and the negated class catches
# it. `-I` skips binary files; `/dev/null` is a second argument so grep prints
# the file name even when given exactly one. The class is a literal range
# (tab, then space through tilde), not a POSIX class, so it is portable across
# BSD grep, GNU grep, and drop-in replacements.
set -eu
here=$(dirname "$0")
cd "${here}/.."

if [ "$#" -eq 0 ]; then
  # Capture the file list on its own line so a git failure stops the script
  # rather than being masked into an empty (falsely passing) argument list.
  files=$(git ls-files)
  [ -n "${files}" ] || exit 0
  IFS='
'
  # shellcheck disable=SC2086 # split the newline-separated list into arguments
  set -- ${files}
fi

tab=$(printf '\t')
found=$(LC_ALL=C grep -n -I "[^${tab} -~]" "$@" /dev/null || true)

if [ -n "${found}" ]; then
  printf '%s\n' "${found}" >&2
  printf '\nNon-ASCII above. This repository is ASCII only; see the header of %s.\n' \
    "scripts/check-ascii.sh" >&2
  exit 1
fi
