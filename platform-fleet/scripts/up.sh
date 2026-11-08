#!/usr/bin/env bash
# Create one kind cluster per tier cluster in tiers.yaml and bootstrap Flux on
# each, synced to clusters/<tier> in platform-fleet. Idempotent.
#
# GITHUB_TOKEN:   the Flux bootstrap token (fine-grained, platform-fleet only:
#                 contents + administration write, for the deploy key).
# PROMOTER_TOKEN: the promoter's token (app repos: contents, pull requests,
#                 deployments write). Stored only as a Secret in each cluster.
# STAGGER=false:  don't wait for each cluster to be Ready before starting the
#                 next (faster on a big machine; on a laptop, three clusters
#                 installing at once starve each other's control planes).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
: "${GITHUB_TOKEN:?set GITHUB_TOKEN to the Flux bootstrap token for $OWNER/platform-fleet}"
FLUX_VERSION=${FLUX_VERSION:-v2.10.0}

# Optional tier names (task up -- dev stg): only those, in tiers.yaml order.
selected=$(tiers)
if [ $# -gt 0 ]; then
  for t in "$@"; do tiers | grep -qx "$t" || die "unknown tier $t (tiers.yaml: $(tiers | xargs))"; done
  selected=$(tiers | grep -xF -f <(printf '%s\n' "$@"))
fi

for tier in $selected; do
  for ctx in $(tier_contexts "$tier"); do
    name=$(kind_name "$ctx")
    if kind get clusters 2>/dev/null | grep -qx "$name"; then
      echo "== $name exists"
    else
      echo "== creating $name"
      kind create cluster --name "$name" --config "$FLEET_DIR/kind/cluster.yaml" --wait 120s
    fi
    # Per-cluster identity and promoter Secrets, before Flux applies anything
    # that references them. Never committed.
    k() { kubectl --context "$ctx" "$@"; }
    for ns in flux-system promoter; do k create namespace "$ns" --dry-run=client -o yaml | k apply -f - >/dev/null; done
    k -n flux-system create configmap cluster-identity --from-literal=CLUSTER_NAME="$ctx" \
      --dry-run=client -o yaml | k apply -f - >/dev/null
    if [ -n "${PROMOTER_TOKEN:-}" ]; then
      k -n promoter create secret generic promoter-github --from-literal=token="$PROMOTER_TOKEN" \
        --dry-run=client -o yaml | k apply -f - >/dev/null
    else
      echo "warning: PROMOTER_TOKEN not set; the in-cluster promoter will not start on $ctx"
    fi

    echo "== bootstrapping Flux on $ctx -> clusters/$tier"
    flux bootstrap github \
      --context "$ctx" \
      --owner "$OWNER" --repository platform-fleet --personal \
      --branch main --path "clusters/$tier" \
      --version "$FLUX_VERSION"
    if [ "${STAGGER:-true}" = true ]; then
      echo "== waiting for every Kustomization on $ctx to be Ready (up to 30m; STAGGER=false to skip)"
      start=$(date +%s)
      until [ "$(kubectl --context "$ctx" -n flux-system get kustomizations -o json 2>/dev/null \
                 | jq 'if any(.items[]; .metadata.name == "canary") | not then -1
                       else [.items[] | select(([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length) == 0)] | length end')" = 0 ]; do
        if [ $(( $(date +%s) - start )) -gt 1800 ]; then
          echo "warning: $ctx not fully Ready after 30m; continuing (check task status)"; break
        fi
        printf '.'; sleep 20
      done
      echo " $ctx ready after $(( ($(date +%s) - start) / 60 ))m"
    fi
  done
done
echo
echo "Clusters are reconciling. Watch with: task status"
