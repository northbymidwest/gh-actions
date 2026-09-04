# Changelog

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
