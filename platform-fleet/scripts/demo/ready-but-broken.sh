#!/usr/bin/env bash
# demo:ready-but-broken — a values change that drops the canary's scrape
# target: the kubernetes-pods job is limited to "platform namespaces". The
# HelmRelease is Ready, but the gate blocks it in the first tier on "canary
# scraped". Ready ≠ validated.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"; source "$(dirname "$0")/lib.sh"
app=prometheus; repo=$(app_repo "$app"); ns=$(app_namespace "$app")
preflight
first=$(first_tier); second=$(tiers | sed -n 2p)
ctx=$(tier_contexts "$first" | head -1)

step "1. Change a shared value in tiers/$first/release.yaml: pod discovery only keeps platform namespaces"
dir=$(clone_repo "$repo")
yq -i '(select(.kind == "HelmRelease") | .spec.values.scrapeConfigs."kubernetes-pods".pre_relabel_configs) = "- source_labels: [__meta_kubernetes_namespace]\n  regex: kube-system|prometheus|otel|kyverno\n  action: keep\n"' \
  "$dir/tiers/$first/release.yaml"
git -C "$dir" --no-pager diff --stat
git -C "$dir" commit -qam "prometheus: only scrape platform namespaces"
pr=$(open_pr "$dir" "promote/$first/demo-broken" "prometheus: only scrape platform namespaces" \
  "Demo: looks harmless, renders fine, HelmRelease will be Ready." promotion)
info "$pr"
wait_until 900 "PR merged (guardrails pass: same digest, valid release.yaml)" is_merged "$pr"
commit=$(release_commit "$repo" "$first")

step "2. Flux applies it; the HelmRelease goes Ready"
wait_until 900 "HelmRelease $ns/$app Ready with the new values" \
  bash -c "kubectl --context $ctx -n $ns get helmrelease $app -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' | grep -qx True && \
           kubectl --context $ctx -n $ns get configmap prometheus -o jsonpath='{.data.prometheus\.yml}' | grep -q 'kube-system|prometheus|otel|kyverno'"
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
