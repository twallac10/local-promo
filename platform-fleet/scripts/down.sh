#!/usr/bin/env bash
# Delete tier clusters: all of them, or only the named tiers (task down -- prd).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
selected=$(tiers)
if [ $# -gt 0 ]; then
  for t in "$@"; do tiers | grep -qx "$t" || die "unknown tier $t (tiers.yaml: $(tiers | xargs))"; done
  selected="$*"
fi
for tier in $selected; do
  for ctx in $(tier_contexts "$tier"); do kind delete cluster --name "$(kind_name "$ctx")"; done
done
