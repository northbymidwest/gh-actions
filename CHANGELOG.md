# Changelog

## 0.5.1 - 2026-09-17

### Changed

- `macos-notarize` documents that submitting a disk image covers the application
  inside it, so a separate submission of the application is not needed. The
  previous wording recommended notarizing both, which costs a round trip per
  release for a ticket on the copy inside the image, and that copy cannot be
  stapled anyway without rebuilding the image and invalidating its own ticket.
  Verified by submitting an image built from an application that had never been
  notarized, then stapling the loose application successfully.

## 0.5.0 - 2026-09-17

### Added

- `release-preflight` takes `manifests`: files whose version must equal the
  release version, saying nothing about publishing. `crates` already checked the
  version, but welded to an assertion that `publish = false` has been removed,
  which is right for something going to crates.io and exactly wrong for a
  repository that ships an application and keeps its manifests unpublished. Such
  a consumer had to write the version check itself.
- `release-preflight` takes `refuse-existing-release`, off by default: also
  refuse when a GitHub release already exists for the version. A draft release
  holds its tag name without creating the tag, so the tag check alone lets a
  second run leave two drafts for one version. Wanted by a consumer that creates
  drafts for review.

## 0.4.0 - 2026-09-17

### Added

- `macos-signing-keychain`, `macos-dmg` and `macos-notarize`: the three steps a
  signed, notarized macOS application needs that a crate release does not. A
  certificate has to reach a runner without lingering on it, a disk image is
  what a person is handed, and the round trip through Apple takes minutes and
  can reject the artifact.
- The three are split where a consumer might want only one. A pull request can
  build and package with no certificate, and gets an unsigned image with a
  warning rather than a failure.
- `macos-dmg` takes a `ds-store` input, which positions the icons and sizes the
  window Finder opens. Arranging a disk image is AppleScript against Finder and
  a runner has no Finder, so the consumer generates the file once on a real Mac
  and commits it. The action renames it into place, because a `.gitignore`
  almost always excludes `.DS_Store`.
- `macos-signing-keychain` takes a `remove` input rather than cleaning up after
  itself, because a composite action cannot register a post step. Call it again
  behind `if: always()`; it is quiet when there is nothing to remove.

## 0.3.0 - 2026-09-11

### Changed

- `release-preflight` now waits for the CI run on the release commit to finish
  instead of failing when it is still queued, in progress, or not yet
  scheduled. A release dispatched right after the version bump used to race
  its own CI run and report `'none'`. It polls every `ci-poll-seconds` (30)
  for up to `ci-wait-minutes` (30); `0` restores the old check-once behaviour.
  The preflight job's `timeout-minutes` must exceed the wait, so consumers
  that keep the default should raise it above 30 when re-pinning.

## 0.2.2 - 2026-09-04

### Changed

- Each composite's shell now lives in a real `.sh` file (invoked via
  `$GITHUB_ACTION_PATH`) instead of an inline `run:` block, so it is linted
  directly with full file context. No behaviour or interface change; consumers
  on v0.2.1 need not re-pin.

### Added

- `.shellcheckrc` enabling optional checks (require-variable-braces,
  quote-safe-variables, add-default-case, deprecate-which,
  check-extra-masked-returns), with all scripts brought into compliance. This
  fixed real masked-failure bugs: `check-ascii.sh` no longer passes silently
  when `git ls-files` fails, and the release scripts no longer swallow a failed
  `gh ... | jq` mid-pipe.
- `set -o pipefail` in the bash release scripts, so a failure anywhere in a
  future pipe stops the run rather than being masked by the last stage.
- `shfmt` formatting enforced in CI (`-i 2 -ci`).
- An opt-in `.githooks/pre-commit` running the ASCII rule, shellcheck, and
  shfmt on staged shell scripts.
- `release-preflight/lib.sh` extracting the pure logic (version validation and
  the resume / publish-prefix computation) with a dependency-free unit test
  (`release-preflight/test.sh`, run in CI). Writing the tests caught a variable
  rename bug in the refactor.

## 0.2.1 - 2026-09-04

### Changed

- Renamed `release-publish` to `release-publish-crate`: it is the one
  ecosystem-specific composite (it runs `cargo publish`), leaving room for a
  future `release-publish-npm` / `release-publish-go`.
- Ecosystem-neutral review wording: the registry row is labelled `registry`
  (not `crates.io`) and omitted when there is nothing to publish; `not yet
  published; will publish: <names>` replaces `none published`.

## 0.2.0 - 2026-09-03

### Added

- `release-publish` composite action: OIDC token exchange plus a
  `cargo publish` loop over the packages, skipping any already live.
- `release-review-summary` composite action: the approver's table (version,
  commit, CI, tag, crates.io, notes) written to the job summary.

### Changed

- `release-preflight` gains `packages` (crates.io probe driving resume),
  `registry-prereqs` (a dependency that must ship first), and `pins`
  (exact-version pin assertions) inputs, and `publish`/`registry` outputs.
- `release-tag` gains `dry-run` (self-branching, so consumers need no
  separate gate) and `working-directory` inputs.

## 0.1.0 - 2026-09-03

### Added

- `release-preflight` and `release-tag` composite actions, and
  `scripts/setup-release-tagging.sh`.
