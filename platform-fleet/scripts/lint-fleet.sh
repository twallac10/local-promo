#!/usr/bin/env bash
# Validate the fleet's own manifests (generated wiring + canary) for every tier.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
schemas="$FLEET_DIR/.cache/schemas"
"$FLEET_DIR/scripts/schemas.sh" "$schemas"
kc() { kubeconform -strict -summary -schema-location default -schema-location "$schemas/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json" -; }
for tier in $(tiers); do
  echo "== fleet ($tier)"
  kustomize build "$FLEET_DIR/fleet" | sed "s|\${TIER}|$tier|g" | kc
  kc < "$FLEET_DIR/clusters/$tier/platform.yaml"
done
echo "== canary"
kustomize build "$FLEET_DIR/canary" | kc
url=$(yq 'select(.kind=="OCIRepository") | .spec.url' "$FLEET_DIR/canary/ocirepository.yaml")
[[ "$url" == "oci://ghcr.io/$OWNER/charts/"* ]] || die "canary OCIRepository outside GHCR prefix: $url"
