#!/usr/bin/env bash
# Validate the fleet's own manifests (generated wiring + canary) for every tier.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
schemas="$FLEET_DIR/.cache/schemas"
"$FLEET_DIR/scripts/schemas.sh" "$schemas"
kc() { kubeconform -strict -summary -schema-location default -schema-location "$schemas/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json" "$@" -; }
for tier in $(tiers); do
  echo "== fleet ($tier)"
  kustomize build "$FLEET_DIR/fleet" | sed "s|\${TIER}|$tier|g" | kc
  kc < "$FLEET_DIR/clusters/$tier/platform.yaml"
done
echo "== canary"
kustomize build "$FLEET_DIR/canary" | kc
url=$(yq 'select(.kind=="OCIRepository") | .spec.url' "$FLEET_DIR/canary/ocirepository.yaml")
[[ "$url" == "oci://ghcr.io/$OWNER/charts/"* ]] || die "canary OCIRepository outside GHCR prefix: $url"
echo "== promoter"
for tier in $(tiers); do
  ctx=$(tier_contexts "$tier" | head -1)
  kustomize build "$FLEET_DIR/promoter" | sed "s|\${TIER}|$tier|g; s|\${CLUSTER_NAME}|$ctx|g" | kc -skip CustomResourceDefinition
done
kustomize build "$FLEET_DIR/promoter-monitoring" | kc
# The promoter image must be the released VERSION.
v=$(cat "$WORKSPACE/platform-promoter/VERSION")
grep -q "image: ghcr.io/$OWNER/platform-promoter:$v\$" "$FLEET_DIR/promoter/deployment.yaml" \
  || die "promoter/deployment.yaml must use ghcr.io/$OWNER/platform-promoter:$v (platform-promoter/VERSION)"
# The CRD must be the one platform-promoter generates.
cmp -s "$FLEET_DIR/promoter/crd.yaml" "$WORKSPACE/platform-promoter/config/crd/platform.twallac10.io_promotiongates.yaml" \
  || die "promoter/crd.yaml is out of date: copy platform-promoter/config/crd/platform.twallac10.io_promotiongates.yaml"
# Every app has a PromotionGate.
for app in $(app_names); do
  yq -e "select(.kind == \"PromotionGate\" and .spec.app == \"$app\")" "$FLEET_DIR/promoter/gates.yaml" >/dev/null \
    || die "promoter/gates.yaml lacks $app (run task fleet:render)"
done
