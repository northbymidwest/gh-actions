# Changelog

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
- `shfmt` formatting enforced in CI (`-i 2 -ci`).
- An opt-in `.githooks/pre-commit` running the ASCII rule, shellcheck, and
  shfmt on staged shell scripts.

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
