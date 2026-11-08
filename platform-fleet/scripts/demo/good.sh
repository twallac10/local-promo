#!/usr/bin/env bash
# demo:good — bump kube-prometheus-stack's chart version and watch it flow,
# with no manual steps, to a prd PR waiting for environment approval.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"; source "$(dirname "$0")/lib.sh"
app=kube-prometheus-stack; repo=$(app_repo "$app")
version=${DEMO_KPS_VERSION:-93.1.0}
preflight
first=$(first_tier)

step "1. Bump $repo mirror/chart.yaml to $version (an ordinary PR, auto-merge)"
dir=$(clone_repo "$repo")
current=$(yq '.version' "$dir/mirror/chart.yaml")
[ "$current" != "$version" ] || die "mirror/chart.yaml is already $version (task demo:reset, or set DEMO_KPS_VERSION)"
VERSION="$version" yq -i '.version = strenv(VERSION)' "$dir/mirror/chart.yaml"
git -C "$dir" commit -qam "chore: kube-prometheus-stack $current -> $version"
pr=$(open_pr "$dir" "demo/bump-$version" "chore: kube-prometheus-stack $version" "Demo: new upstream chart version. The mirror workflow takes it from here.")
info "$pr"
wait_until 900 "bump PR merged (guardrails pass, no approval for non-promotion PRs)" is_merged "$pr"

step "2. mirror.yaml pushes $version to GHCR and opens the $first entry PR"
wait_until 900 "entry PR promote/$first/*" has_pr "$repo" "promote/$first/"
pr=$(find_pr "$repo" "promote/$first/"); info "$pr"
wait_until 900 "entry PR merged (digest exists in GHCR)" is_merged "$pr"

tiers_arr=($(tiers))
for i in "${!tiers_arr[@]}"; do
  tier=${tiers_arr[$i]}
  commit=$(release_commit "$repo" "$tier")
  step "$((i + 3)). $tier: Flux applies it, each cluster's PromotionGate runs the gate"
  info "release commit ${commit:0:7}"
  for ctx in $(tier_contexts "$tier"); do
    wait_until 1800 "$ctx gate finished" pg_is "$ctx" "$app" "$commit" Passed Promoted Failed
    if pg_is "$ctx" "$app" "$commit" Failed; then show_gates "$app"; die "gate failed in $tier (see kubectl -n promoter get pg $app -o yaml)"; fi
  done
  show_gates "$app"
  next_i=$((i + 1)); [ $next_i -lt ${#tiers_arr[@]} ] || break
  next=${tiers_arr[$next_i]}
  wait_until 900 "promotion PR promote/$next/*" has_pr "$repo" "promote/$next/"
  pr=$(find_pr "$repo" "promote/$next/"); info "$pr"
  approval=$(yq ".tiers[] | select(.name == \"$next\") | .requiresApproval" "$FLEET_DIR/tiers.yaml")
  if [ "$approval" = true ]; then
    step "Done: the $next PR is waiting for environment approval"
    info "$pr"
    info "Diff: only tiers/$next/release.yaml. Evidence tables are in the PR body."
    info "Approve: PR → Checks → promotion → 'Review deployments' (or the Actions run)."
    info "Once approved, promotion-gate passes and the PR merges itself."
    exit 0
  fi
  wait_until 900 "$next PR merged (no approval needed)" is_merged "$pr"
done
