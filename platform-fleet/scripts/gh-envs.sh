#!/usr/bin/env bash
# Configure every app repo in apps.yaml for gated promotion (idempotent):
#   - one GitHub Environment per tier in tiers.yaml; tiers with
#     requiresApproval get required reviewers (APPROVERS) + prevent self-review
#   - deployment branch policy: main and promote/* (the approval job runs on
#     the promotion PR's branch, so main alone would block it; see NOTES.md)
#   - repo: allow auto-merge (squash), delete merged branches
#   - branch protection on main: required check `promotion / promotion-gate`,
#     no required PR reviews (the environment approval is the only approval)
#   - `promotion` label, and the PROMOTER_TOKEN Actions secret if it is set
#
# Env:
#   APPROVERS            comma-separated GitHub logins (default: you)
#   PREVENT_SELF_REVIEW  true (default) | false. With true, whoever triggered
#                        the run cannot approve it. The promotion PR is opened
#                        by the promoter token's owner, so that owner can't
#                        approve: use a separate machine account for
#                        PROMOTER_TOKEN, or set false for a one-person demo.
#   PROMOTER_TOKEN       stored as an Actions secret in each app repo (mirror.yaml uses it)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
CHECK="promotion / promotion-gate"
me=$(gh api user -q .login)
APPROVERS=${APPROVERS:-$me}
PREVENT_SELF_REVIEW=${PREVENT_SELF_REVIEW:-true}

reviewers='[]'
for login in ${APPROVERS//,/ }; do
  id=$(gh api "users/$login" -q .id)
  reviewers=$(jq -c --argjson id "$id" '. + [{"type":"User","id":$id}]' <<<"$reviewers")
done
if [ "$PREVENT_SELF_REVIEW" = true ] && [ -z "${PROMOTER_ACCOUNT:-}" ]; then
  echo "note: prevent self-review is on. If PROMOTER_TOKEN belongs to an approver ($APPROVERS),"
  echo "      that approver cannot approve promotion runs. See the header of this script."
fi

for repo in $(app_repos); do
  r="$OWNER/$repo"
  echo "== $r"
  gh api -X PATCH "repos/$r" -F allow_auto_merge=true -F delete_branch_on_merge=true -F allow_squash_merge=true >/dev/null

  for tier in $(tiers); do
    approval=$(yq ".tiers[] | select(.name == \"$tier\") | .requiresApproval" "$FLEET_DIR/tiers.yaml")
    if [ "$approval" = true ]; then
      body=$(jq -n --argjson r "$reviewers" --argjson p "$PREVENT_SELF_REVIEW" \
        '{wait_timer:0, prevent_self_review:$p, reviewers:$r,
          deployment_branch_policy:{protected_branches:false, custom_branch_policies:true}}')
    else
      body='{"wait_timer":0,"reviewers":[],"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
    fi
    gh api -X PUT "repos/$r/environments/$tier" --input - <<<"$body" >/dev/null
    existing=$(gh api "repos/$r/environments/$tier/deployment-branch-policies" -q '.branch_policies[].name' 2>/dev/null || true)
    for pat in main 'promote/*'; do
      grep -qxF "$pat" <<<"$existing" || gh api "repos/$r/environments/$tier/deployment-branch-policies" -f name="$pat" -f type=branch >/dev/null
    done
    echo "   environment $tier (approval: $approval)"
  done

  gh api -X PUT "repos/$r/branches/main/protection" --input - >/dev/null <<JSON
{
  "required_status_checks": {"strict": false, "contexts": ["$CHECK"]},
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
JSON
  echo "   main requires: $CHECK"

  gh label create promotion --repo "$r" --color 1D76DB --description "Automated tier promotion" --force >/dev/null
  if [ -n "${PROMOTER_TOKEN:-}" ]; then
    gh secret set PROMOTER_TOKEN --repo "$r" --body "$PROMOTER_TOKEN" >/dev/null
    echo "   secret PROMOTER_TOKEN set"
  fi
done
