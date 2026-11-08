#!/usr/bin/env bash
# Build strict JSON schemas for the CRDs our manifests use (Flux, Kyverno,
# Prometheus Operator, PromotionGate) into <out-dir>. Cached; rebuilt whenever
# this script or the PromotionGate CRD changes.
set -euo pipefail
out=${1:?}; here=$(cd "$(dirname "$0")/.." && pwd)
if command -v sha256sum >/dev/null; then sum=(sha256sum); else sum=(shasum -a 256); fi  # macOS: shasum
stamp=$(cat "$here/scripts/schemas.sh" "$here/scripts/crd2schema.py" "$here/promoter/crd.yaml" | "${sum[@]}" | cut -d' ' -f1)
[ "$(cat "$out/.done" 2>/dev/null)" = "$stamp" ] && exit 0
rm -rf "$out"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
flux install --export > "$tmp/flux.yaml"
helm template k kyverno --repo https://kyverno.github.io/kyverno --version 3.9.2 \
  | yq 'select(.kind=="CustomResourceDefinition")' > "$tmp/kyverno.yaml"
helm pull kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 93.0.0 --untar -d "$tmp"
cat "$tmp"/kube-prometheus-stack/charts/crds/crds/*.yaml > "$tmp/prom.yaml"
python3 -I -S "$here/scripts/crd2schema.py" "$out" "$tmp/flux.yaml" "$tmp/kyverno.yaml" "$tmp/prom.yaml" \
  "$here/promoter/crd.yaml"
echo "$stamp" > "$out/.done"
