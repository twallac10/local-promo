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
