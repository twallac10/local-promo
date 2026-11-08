#!/usr/bin/env bash
# demo:ready-but-broken — a values change that drops the canary's scrape
# target (Prometheus ServiceMonitor selector). The HelmRelease is Ready, but
# the gate blocks it in the first tier on "canary scraped". Ready ≠ validated.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"; source "$(dirname "$0")/lib.sh"
app=kube-prometheus-stack; repo=$(app_repo "$app"); ns=$(app_namespace "$app")
preflight
first=$(first_tier); second=$(tiers | sed -n 2p)
ctx=$(tier_contexts "$first" | head -1)

step "1. Change a shared value in tiers/$first/release.yaml: Prometheus only selects ServiceMonitors labelled platform.twallac10.io/scrape=opt-in"
dir=$(clone_repo "$repo")
yq -i '(select(.kind == "HelmRelease") | .spec.values.prometheus.prometheusSpec.serviceMonitorSelector) = {"matchLabels": {"platform.twallac10.io/scrape": "opt-in"}}' \
  "$dir/tiers/$first/release.yaml"
git -C "$dir" --no-pager diff --stat
git -C "$dir" commit -qam "kube-prometheus-stack: only scrape opt-in ServiceMonitors"
pr=$(open_pr "$dir" "promote/$first/demo-broken" "kube-prometheus-stack: only scrape opt-in ServiceMonitors" \
  "Demo: looks harmless, renders fine, HelmRelease will be Ready." promotion)
info "$pr"
wait_until 900 "PR merged (guardrails pass: same digest, valid release.yaml)" is_merged "$pr"
commit=$(release_commit "$repo" "$first")

step "2. Flux applies it; the HelmRelease goes Ready"
wait_until 900 "HelmRelease $ns/$app Ready with the new values" \
  bash -c "kubectl --context $ctx -n $ns get helmrelease $app -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True && \
           kubectl --context $ctx -n monitoring get prometheus -o jsonpath='{..serviceMonitorSelector.matchLabels}' | grep -q opt-in"
kubectl --context "$ctx" -n "$ns" get helmrelease "$app"

step "3. The gate runs on $ctx and blocks it (waits for canary scrapes, up to maxWait)"
wait_until 1200 "PromotionGate $app failed for ${commit:0:7}" pg_is "$ctx" "$app" "$commit" Failed
kubectl --context "$ctx" -n promoter get promotiongate "$app"
echo
kubectl --context "$ctx" -n promoter get promotiongate "$app" -o json \
  | jq -r '.status.lastGate.results[] | "  \(.status | ascii_upcase)\t\(.name)\t\(.reason // .value)"' | column -t -s $'\t'

step "4. Where the reason is visible"
info "Kubernetes Event on the HelmRelease:"
kubectl --context "$ctx" -n "$ns" get events --field-selector "involvedObject.name=$app,reason=PromotionGateFailed" \
  -o custom-columns=TYPE:.type,REASON:.reason,MESSAGE:.message --sort-by=.lastTimestamp | tail -2
info "GitHub Deployment ($first environment):"
gh api "repos/$OWNER/$repo/deployments?environment=$first&task=gate&per_page=1" -q '.[0].id' \
  | xargs -I{} gh api "repos/$OWNER/$repo/deployments/{}/statuses?per_page=1" -q '.[0] | "  \(.state): \(.description)\n  evidence: \(.log_url)"'
if has_pr "$repo" "promote/$second/"; then die "a $second PR was opened despite the failed gate"; fi
info "No $second PR was opened. Revert with: task demo:reset"
