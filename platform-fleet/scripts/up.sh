#!/usr/bin/env bash
# Create one kind cluster per tier cluster in tiers.yaml and bootstrap Flux on
# each, synced to clusters/<tier> in platform-fleet. Idempotent.
#
# GITHUB_TOKEN: the Flux bootstrap token (fine-grained, platform-fleet only:
# contents + administration write, for the deploy key). Not the promoter token.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
: "${GITHUB_TOKEN:?set GITHUB_TOKEN to the Flux bootstrap token for $OWNER/platform-fleet}"
FLUX_VERSION=${FLUX_VERSION:-v2.10.0}

for tier in $(tiers); do
  for ctx in $(tier_contexts "$tier"); do
    name=$(kind_name "$ctx")
    if kind get clusters 2>/dev/null | grep -qx "$name"; then
      echo "== $name exists"
    else
      echo "== creating $name"
      kind create cluster --name "$name" --config "$FLEET_DIR/kind/cluster.yaml" --wait 120s
    fi
    echo "== bootstrapping Flux on $ctx -> clusters/$tier"
    flux bootstrap github \
      --context "$ctx" \
      --owner "$OWNER" --repository platform-fleet --personal \
      --branch main --path "clusters/$tier" \
      --version "$FLUX_VERSION" \
      --silent
  done
done
echo
echo "Clusters are reconciling. Watch with: task status"
