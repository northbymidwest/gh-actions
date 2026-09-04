# gh-actions

[![github](https://img.shields.io/badge/github-northbymidwest%2Fgh--actions-blue?logo=github)](https://github.com/northbymidwest/gh-actions)
[![CI](https://github.com/northbymidwest/gh-actions/actions/workflows/ci.yml/badge.svg)](https://github.com/northbymidwest/gh-actions/actions/workflows/ci.yml)

Reusable pieces of the release workflow shared by the northbymidwest
repositories, so the recipe lives in one place and every consumer pins it
by commit SHA like any other action.

| path | what it is |
| --- | --- |
| `release-preflight/` | Composite action: the checks a release must pass before anything irreversible happens, and the crates.io probe that drives resume. |
| `release-publish-crate/` | Composite action: exchange an OIDC token and `cargo publish` each package, skipping any already live. |
| `release-tag/` | Composite action: push the protected `v<version>` tag with a deploy key and cut the GitHub release from the changelog. |
| `release-review-summary/` | Composite action: write the table a release approver reads (version, commit, CI, tag, crates.io, notes) to the job summary. |
| `scripts/setup-release-tagging.sh` | Idempotent provisioning of what `release-tag` needs on a repository: the `release` environment, the tag ruleset, and the deploy key plus its secret. |

## The release shape these support

A release is dispatched by hand with a version and a `dry_run` flag. A
`preflight` job with no write scope validates everything and writes the
approver's summary; a `publish` job gated by the `release` environment's
required reviewer does the irreversible uploads and only then tags. The tag
is an output of a succeeded release, never its trigger: a protected `v*` tag
is permanent the moment it lands, so a tag-triggered release would burn a
version on any downstream failure.

`cargo publish` runs in the consumer's own workflow (via `release-publish-crate`, a
composite, not a reusable workflow) so the trusted-publishing OIDC identity
stays the consumer's release workflow, which is what each crate's
trusted-publisher entry is bound to.

```yaml
name: release
run-name: release ${{ inputs.version }}${{ inputs.dry_run && ' (dry run)' || '' }}
on:
  workflow_dispatch:
    inputs:
      version: { description: 'Version, no leading v', type: string, required: true }
      dry_run: { description: 'Stop before publishing', type: boolean, required: true, default: true }
permissions:
  contents: read
concurrency:
  group: release
  cancel-in-progress: false

jobs:
  preflight:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      actions: read
    outputs:
      publish: ${{ steps.pre.outputs.publish }}
    steps:
      - uses: actions/checkout@<sha> # vN
        with:
          persist-credentials: false
      - id: pre
        uses: northbymidwest/gh-actions/release-preflight@<sha> # vN
        with:
          version: ${{ inputs.version }}
          dry-run: ${{ inputs.dry_run }}
          crates: Cargo.toml
          packages: my-crate
          token: ${{ github.token }}
      - uses: northbymidwest/gh-actions/release-review-summary@<sha> # vN
        with:
          version: ${{ inputs.version }}
          dry-run: ${{ inputs.dry_run }}
          tag: ${{ steps.pre.outputs.tag }}
          registry: ${{ steps.pre.outputs.registry }}
          what-approving-does: publishes my-crate and tags v${{ inputs.version }}
          token: ${{ github.token }}

  publish:
    needs: preflight
    environment: release
    runs-on: ubuntu-latest
    permissions:
      contents: write
      id-token: write
    steps:
      - uses: actions/checkout@<sha> # vN
        with:
          persist-credentials: false
      - uses: dtolnay/rust-toolchain@<sha> # stable
        with:
          toolchain: stable
      - uses: northbymidwest/gh-actions/release-publish-crate@<sha> # vN
        with:
          packages: my-crate
          publish: ${{ needs.preflight.outputs.publish }}
          dry-run: ${{ inputs.dry_run }}
      - uses: northbymidwest/gh-actions/release-tag@<sha> # vN
        with:
          version: ${{ inputs.version }}
          deploy-key: ${{ secrets.RELEASE_TAG_KEY }}
          token: ${{ github.token }}
          dry-run: ${{ inputs.dry_run }}
```

### Multiple crates, other runners, cross-repo dependencies

- **Lockstep crates:** list every manifest in `crates` (one path per line) and
  every crate in `packages` and `release-publish-crate`'s `packages`, in publish
  order. `release-preflight` reports which still need uploading (resume), and
  `release-publish-crate` skips the rest.
- **A crate that links a private framework:** run `publish` on `macos-latest`
  and pass `args: --no-default-features` to `release-publish-crate` if the default
  features raise the toolchain floor past the runner.
- **A path dependency on another repo:** check that repo out as a sibling in
  the `publish` job (the same `path:` layout CI uses) and pass
  `release-publish-crate` / `release-tag` a `working-directory` pointing at your
  repo's checkout, since composite steps do not inherit
  `defaults.run.working-directory`.
- **A registry dependency that must ship first:** pass
  `registry-prereqs: <crate>=<manifest>` to `release-preflight`; it reads the
  required version from that manifest and fails unless it is already on
  crates.io.
- **A facade that exact-pins a sibling:** pass `pins: <manifest>|<dep>|` to
  assert the manifest pins `<dep> = "=<version>"` at the release version.

`release-preflight` outputs `tag` (`free` or `exists`), `publish` (a JSON
array of the packages still needing upload), and `registry` (a one-line
summary). Feed `publish` to `release-publish-crate`, and `tag`/`registry` to
`release-review-summary`.

## Provisioning a repository

```
scripts/setup-release-tagging.sh OWNER/REPO
scripts/setup-release-tagging.sh --rotate OWNER/REPO   # replace the deploy key and its secret together
```

It creates only what is missing: the `release` environment with the caller
as required reviewer and `main` as its only allowed branch; the
`protect version tags` ruleset (no create, update, delete, or force-push of
`refs/tags/v*`) whose only bypass actor is a deploy key; and a read-write
deploy key whose private half is stored solely as the environment secret
`RELEASE_TAG_KEY`. The key is generated in a temporary directory and
destroyed after upload, so no copy exists outside GitHub.

## Pinning

Consumers pin `northbymidwest/gh-actions/<action>@<full sha>` with a
trailing `# <tag>` comment, e.g. `# v0.2.1`; Dependabot's `github-actions`
ecosystem matches the comment against this repository's tags and moves the
pin like any other action, which is why every release here is tagged.

## License

[BSD Zero Clause License](LICENSE)
