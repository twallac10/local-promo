#!/usr/bin/env bash
# Flux Kustomizations and HelmReleases per tier cluster, then the latest gate
# (GitHub Deployment) per app per tier.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

# One line per object: kind, namespace/name, Ready status/reason, message
# (multi-line messages flattened and cut to fit).
rows() {
  kubectl --context "$1" get "$2" -A -o json 2>/dev/null | jq -r --arg k "$3" '
    .items[] | (.status.conditions // [] | map(select(.type == "Ready")) | first) as $c
    | [$k, "\(.metadata.namespace)/\(.metadata.name)",
       (if $c then "\($c.status)" else "?" end),
       (if $c and $c.status != "True" then $c.reason else "" end),
       (($c.message // "") | gsub("\\s+"; " ") | .[0:110])] | @tsv' \
  | awk -F'\t' '{ printf "  %-3s %-40s %-6s %-22s %s\n", $1, $2, $3, $4, $5 }'
}

for tier in $(tiers); do
  for ctx in $(tier_contexts "$tier"); do
    echo "=== $tier ($ctx)"
    if ! kubectl --context "$ctx" get ns flux-system >/dev/null 2>&1; then echo "  (unreachable or not bootstrapped)"; continue; fi
    rows "$ctx" kustomizations.kustomize.toolkit.fluxcd.io ks
    rows "$ctx" helmreleases.helm.toolkit.fluxcd.io hr
    if kubectl --context "$ctx" get crd promotiongates.platform.twallac10.io >/dev/null 2>&1; then
      kubectl --context "$ctx" -n promoter get promotiongates -o json | jq -r '.items[] |
        ["pg", .metadata.name, (.status.phase // "-"), ((.status.message // "") | gsub("\\s+"; " ") | .[0:100])] | @tsv' \
        | awk -F'\t' '{ printf "  %-3s %-40s %-9s %s\n", $1, $2, $3, $4 }'
    fi
  done
done

# Deployment ledger: latest gate per app per tier.
echo
echo "=== latest gate per app per tier (GitHub Deployments: state version digest)"
if ! command -v gh >/dev/null || ! gh auth status >/dev/null 2>&1; then echo "  (gh not authenticated)"; exit 0; fi
printf '  %-24s' app; for tier in $(tiers); do printf '%-28s' "$tier"; done; echo
for app in $(app_names); do
  repo=$(app_repo "$app"); printf '  %-24s' "$app"
  for tier in $(tiers); do
    cell="-"
    if dep=$(gh api "repos/$OWNER/$repo/deployments?environment=$tier&task=gate&per_page=1" \
          -q '.[0] // empty | [.id, (.payload.version // "?"), ((.payload.digest // "") | ltrimstr("sha256:") | .[0:7])] | @tsv' 2>/dev/null) \
       && [ -n "$dep" ]; then
      read -r id ver dig <<<"$dep"
      state=$(gh api "repos/$OWNER/$repo/deployments/$id/statuses?per_page=1" -q '.[0].state // "created"' 2>/dev/null || echo "?")
      cell="$state $ver $dig"
    fi
    printf '%-28s' "$cell"
  done
  echo
done
