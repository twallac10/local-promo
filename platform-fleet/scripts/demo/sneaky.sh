#!/usr/bin/env bash
# demo:sneaky — a promotion PR into the second tier that also flips
# kyverno-policies' validationFailureAction (tier config) is rejected by CI.
set -euo pipefail
source "$(dirname "$0")/../lib.sh"; source "$(dirname "$0")/lib.sh"
app=kyverno-policies; repo=$(app_repo "$app")
preflight
first=$(first_tier); target=$(tiers | sed -n 2p)

step "1. A 'promotion' $first → $target that also sets validationFailureAction: Enforce in tiers/$target/tier.yaml"
dir=$(clone_repo "$repo")
cp "$dir/tiers/$first/release.yaml" "$dir/tiers/$target/release.yaml"
yq -i '.spec.values.validationFailureAction = "Enforce"' "$dir/tiers/$target/tier.yaml"
# Ensure the release file differs too, so it looks like a real promotion.
grep -q 'demo: sneaky' "$dir/tiers/$target/release.yaml" || echo "# demo: sneaky" >> "$dir/tiers/$target/release.yaml"
git -C "$dir" add -A
git -C "$dir" commit -qm "promote($target): $app from $first"
git -C "$dir" --no-pager show --stat --format='  %s' HEAD
pr=$(open_pr "$dir" "promote/$target/sneaky-$(date +%s)" "promote($target): $app from $first" \
  "Demo: a promotion PR that smuggles in a tier.yaml change." promotion)
info "$pr"

step "2. CI (promotion / promotion-gate) must reject it"
set +e
gh pr checks "$pr" --watch --interval 10 >/dev/null 2>&1
set -e
gh pr checks "$pr" || true
if is_merged "$pr"; then die "the sneaky PR was merged"; fi
bucket=$(gh pr checks "$pr" --json name,bucket -q '.[] | select(.name | test("promotion-gate")) | .bucket')
[ "$bucket" = fail ] || die "promotion-gate is '$bucket', expected fail"
info "Rejected. The guardrails job summary lists: only tiers/<target>/release.yaml may change."
gh pr close "$pr" --delete-branch --comment "Demo: rejected by the promotion guardrails, as intended." >/dev/null
info "PR closed."
