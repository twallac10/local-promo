#!/usr/bin/env bash
# Build strict JSON schemas for the CRDs our manifests use (Flux, Kyverno,
# Prometheus Operator) into <out-dir>. Cached: delete the dir to refresh.
set -euo pipefail
out=${1:?}; here=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$out/.done" ] && exit 0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
flux install --export > "$tmp/flux.yaml"
helm template k kyverno --repo https://kyverno.github.io/kyverno --version 3.9.2 \
  | yq 'select(.kind=="CustomResourceDefinition")' > "$tmp/kyverno.yaml"
helm pull kube-prometheus-stack --repo https://prometheus-community.github.io/helm-charts --version 93.0.0 --untar -d "$tmp"
cat "$tmp"/kube-prometheus-stack/charts/crds/crds/*.yaml > "$tmp/prom.yaml"
python3 "$here/scripts/crd2schema.py" "$out" "$tmp/flux.yaml" "$tmp/kyverno.yaml" "$tmp/prom.yaml" \
  "$here/promoter/crd.yaml"
touch "$out/.done"
