# gh-actions

Reusable pieces of the release workflow shared by the northbymidwest
repositories, so the recipe lives in one place and every consumer pins it
by commit SHA like any other action.

| path | what it is |
| --- | --- |
| `release-preflight/` | Composite action: the checks a release must pass before anything irreversible happens. |
| `release-tag/` | Composite action: push the protected `v<version>` tag with a deploy key and cut the GitHub release from the changelog. |
| `scripts/setup-release-tagging.sh` | Idempotent provisioning of what `release-tag` needs on a repository: the `release` environment, the tag ruleset, and the deploy key plus its secret. |

## The release shape these support

A release is dispatched by hand with a version and a `dry_run` flag. A
`preflight` job with no write scope validates everything; a `publish` job
gated by the `release` environment's required reviewer does the irreversible
uploads and only then tags. The tag is an output of a succeeded release,
never its trigger: a protected `v*` tag is permanent the moment it lands, so
a tag-triggered release would burn a version on any downstream failure.

```yaml
jobs:
  preflight:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      actions: read
    steps:
      - uses: actions/checkout@<sha> # vN
        with:
          persist-credentials: false
      - uses: northbymidwest/gh-actions/release-preflight@<sha>
        with:
          version: ${{ inputs.version }}
          dry-run: ${{ inputs.dry_run }}
          crates: Cargo.toml
          token: ${{ github.token }}

  publish:
    needs: preflight
    environment: release
    permissions:
      contents: write
      id-token: write
    steps:
      - uses: actions/checkout@<sha> # vN
        with:
          persist-credentials: false
      # ... exchange the OIDC token, cargo publish ...
      - uses: northbymidwest/gh-actions/release-tag@<sha>
        if: ${{ !inputs.dry_run }}
        with:
          version: ${{ inputs.version }}
          deploy-key: ${{ secrets.RELEASE_TAG_KEY }}
          token: ${{ github.token }}
```

`release-preflight` takes `crates` as newline-separated `Cargo.toml` paths
(one per line for a workspace that releases several crates in lockstep) and
exposes `tag` (`free` or `exists`) as an output.

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
trailing `# <short sha or tag>` comment; Dependabot's `github-actions`
ecosystem moves the pin like any other action.

## License

[BSD Zero Clause License](LICENSE)
