#!/usr/bin/env bash
# Provisions everything a release workflow needs to push a protected v* tag
# through the release-tag action, idempotently, on one repository:
#
#   1. a `release` environment with one required reviewer and a deployment
#      branch policy allowing only `main`;
#   2. a `protect version tags` ruleset (no create / update / delete /
#      force-push of refs/tags/v*) whose only bypass actor is a deploy key;
#   3. a read-write deploy key whose private half is stored ONLY as the
#      environment secret RELEASE_TAG_KEY. The key is generated in a temp dir
#      and destroyed after upload; no copy survives on this machine.
#
# Re-running is safe: each piece is created only if missing. `--rotate`
# replaces the deploy key and the secret together.
#
#   scripts/setup-release-tagging.sh [--rotate] [--reviewer LOGIN] OWNER/REPO
#
# Needs gh (authenticated as an admin of the repo) and ssh-keygen.
set -euo pipefail

ROTATE=false
REVIEWER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rotate)
      ROTATE=true
      shift
      ;;
    --reviewer)
      REVIEWER="$2"
      shift 2
      ;;
    -*)
      echo "unknown flag $1" >&2
      exit 2
      ;;
    *) break ;;
  esac
done
[ "$#" -eq 1 ] || {
  echo "usage: $0 [--rotate] [--reviewer LOGIN] OWNER/REPO" >&2
  exit 2
}
REPO="$1"
ENV_NAME="release"
SECRET_NAME="RELEASE_TAG_KEY"
RULESET_NAME="protect version tags"
KEY_TITLE="release workflow: creates v* tags (bypass actor on the tag ruleset; private half is the release environment secret ${SECRET_NAME})"

[ -n "${REVIEWER}" ] || REVIEWER=$(gh api user -q .login)
reviewer_id=$(gh api "users/${REVIEWER}" -q .id)

echo "== ${REPO}"

# 1. Environment: reviewer and main-only branch policy.
gh api -X PUT "repos/${REPO}/environments/${ENV_NAME}" --input - >/dev/null <<JSON
{"wait_timer":0,"prevent_self_review":false,"reviewers":[{"type":"User","id":${reviewer_id}}],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
policies=$(gh api "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies" -q '.branch_policies[].name')
if ! grep -qx main <<<"${policies}"; then
  gh api -X POST "repos/${REPO}/environments/${ENV_NAME}/deployment-branch-policies" --input - >/dev/null <<'JSON'
{"name":"main","type":"branch"}
JSON
fi
echo "environment ${ENV_NAME}: reviewer ${REVIEWER}, branches: main"

# 2. Tag ruleset with a deploy-key bypass.
existing=$(gh api "repos/${REPO}/rulesets" -q ".[] | select(.name == \"${RULESET_NAME}\") | .id")
existing=${existing%%$'\n'*}
if [ -z "${existing}" ]; then
  gh api -X POST "repos/${REPO}/rulesets" --input - >/dev/null <<'JSON'
{"name":"protect version tags","target":"tag","enforcement":"active","bypass_actors":[{"actor_id":null,"actor_type":"DeployKey","bypass_mode":"always"}],"conditions":{"ref_name":{"include":["refs/tags/v*"],"exclude":[]}},"rules":[{"type":"deletion"},{"type":"non_fast_forward"},{"type":"update"},{"type":"creation"}]}
JSON
  echo "ruleset '${RULESET_NAME}': created"
else
  actors=$(gh api "repos/${REPO}/rulesets/${existing}" -q '.bypass_actors[].actor_type')
  if grep -qx DeployKey <<<"${actors}"; then
    echo "ruleset '${RULESET_NAME}': present (deploy-key bypass)"
  else
    echo "ruleset '${RULESET_NAME}': present but has NO deploy-key bypass; add one or the tag push will be refused" >&2
  fi
fi

# 3. Deploy key and secret, together.
key_id=$(gh repo deploy-key list --repo "${REPO}" --json id,title -q ".[] | select(.title == \"${KEY_TITLE}\") | .id")
key_id=${key_id%%$'\n'*}
secret_present=false
secrets=$(gh api "repos/${REPO}/environments/${ENV_NAME}/secrets" -q '.secrets[].name')
if grep -qx "${SECRET_NAME}" <<<"${secrets}"; then
  secret_present=true
fi
if [ -n "${key_id}" ] && [ "${secret_present}" = true ] && [ "${ROTATE}" = false ]; then
  echo "deploy key + ${SECRET_NAME}: present (use --rotate to replace both)"
else
  if [ -n "${key_id}" ] && [ "${secret_present}" = false ] && [ "${ROTATE}" = false ]; then
    echo "deploy key exists but ${SECRET_NAME} is missing; rotating so they match" >&2
  fi
  dir=$(mktemp -d)
  trap 'rm -rf "${dir}"' EXIT
  ssh-keygen -q -t ed25519 -N "" -C "${REPO} release tag key" -f "${dir}/key"
  if [ -n "${key_id}" ]; then
    gh repo deploy-key delete "${key_id}" --repo "${REPO}"
  fi
  gh repo deploy-key add "${dir}/key.pub" --repo "${REPO}" --allow-write --title "${KEY_TITLE}" >/dev/null
  gh secret set "${SECRET_NAME}" --repo "${REPO}" --env "${ENV_NAME}" <"${dir}/key"
  rm -f "${dir}/key" "${dir}/key.pub"
  echo "deploy key + ${SECRET_NAME}: created (private half stored only as the environment secret)"
fi
