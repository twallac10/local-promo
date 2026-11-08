#!/usr/bin/env bash
# Port-forward a tier's Prometheus UI. Usage: prometheus.sh <tier>
# (each tier gets its own port: 9090 + tier index)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
tier=${1:?usage: task prometheus -- <tier>}
idx=$(yq ".tiers | to_entries | .[] | select(.value.name == \"$tier\") | .key" "$FLEET_DIR/tiers.yaml")
[ -n "$idx" ] || die "unknown tier $tier (tiers.yaml: $(tiers | xargs))"
ctx=$(tier_contexts "$tier" | head -1)
port=$((9090 + idx))
echo "Prometheus for $tier ($ctx): http://localhost:$port   (canary: up{namespace=\"canary\"})"
( sleep 2; command -v open >/dev/null && open "http://localhost:$port" || command -v xdg-open >/dev/null && xdg-open "http://localhost:$port" ) >/dev/null 2>&1 &
exec kubectl --context "$ctx" -n prometheus port-forward svc/prometheus "$port:9090"
