#!/usr/bin/env bash
# Port-forward a tier's Grafana and print the admin login.
# Usage: grafana.sh <tier>   (each tier gets its own port: 3000 + tier index)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
tier=${1:?usage: task grafana -- <tier>}
idx=$(yq ".tiers | to_entries | .[] | select(.value.name == \"$tier\") | .key" "$FLEET_DIR/tiers.yaml")
[ -n "$idx" ] || die "unknown tier $tier (tiers.yaml: $(tiers | xargs))"
ctx=$(tier_contexts "$tier" | head -1)
port=$((3000 + idx))
pass=$(kubectl --context "$ctx" -n monitoring get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)
echo "Grafana for $tier ($ctx): http://localhost:$port   user: admin   password: $pass"
( sleep 2; command -v open >/dev/null && open "http://localhost:$port" || command -v xdg-open >/dev/null && xdg-open "http://localhost:$port" ) >/dev/null 2>&1 &
exec kubectl --context "$ctx" -n monitoring port-forward svc/grafana "$port:80"
