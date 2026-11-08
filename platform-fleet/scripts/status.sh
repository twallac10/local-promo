#!/usr/bin/env bash
# Flux Kustomizations and HelmReleases per tier cluster.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
for tier in $(tiers); do
  for ctx in $(tier_contexts "$tier"); do
    echo "=== $tier ($ctx)"
    if ! kubectl --context "$ctx" get ns flux-system >/dev/null 2>&1; then echo "  (unreachable or not bootstrapped)"; continue; fi
    flux --context "$ctx" get kustomizations -A --no-header 2>/dev/null | awk '{printf "  ks  %-24s ready=%-6s %s\n", $2, $4, $3}'
    flux --context "$ctx" get helmreleases -A --no-header 2>/dev/null | awk '{printf "  hr  %-24s ready=%-6s %s\n", $2, $5, $3}'
  done
done

# Deployment ledger: latest gate per app per tier (GitHub Deployments).
echo
echo "=== latest gate per app per tier (GitHub Deployments)"
if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then echo "  (gh not authenticated)"; exit 0; fi
printf '  %-22s' app; for tier in $(tiers); do printf '%-22s' "$tier"; done; echo
for app in $(app_names); do
  repo=$(app_repo "$app"); printf '  %-22s' "$app"
  for tier in $(tiers); do
    cell=$(gh api "repos/$OWNER/$repo/deployments?environment=$tier&task=gate&per_page=1" \
      -q '.[0] | [.id, .payload.version, (.payload.digest // "" | ltrimstr("sha256:") | .[0:7])] | @tsv' 2>/dev/null || true)
    if [ -z "$cell" ]; then printf '%-22s' "-"; continue; fi
    read -r id ver dig <<<"$cell"
    state=$(gh api "repos/$OWNER/$repo/deployments/$id/statuses?per_page=1" -q '.[0].state' 2>/dev/null || echo "?")
    printf '%-22s' "$state $ver $dig"
  done
  echo
done
