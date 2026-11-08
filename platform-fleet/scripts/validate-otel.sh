#!/usr/bin/env bash
# Validate the rendered OpenTelemetry Collector config with the pinned image
# itself (`otelcol validate`): catches components the chosen distribution
# doesn't include, which only fail at runtime otherwise. Needs docker; skipped
# (with a note) when docker isn't available.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
repo="$WORKSPACE/platform-otel-collector"
[ -d "$repo" ] || exit 0
if ! docker info >/dev/null 2>&1; then echo "== otel config: skipped (docker not running)"; exit 0; fi
work=$(mktemp -d); chmod 755 "$work"; trap 'rm -rf "$work"' EXIT
chart=$("$FLEET_DIR/scripts/upstream-chart.sh" "$repo" "$FLEET_DIR/.cache/charts")
for tier in $(tiers); do
  out=$(kustomize build "$repo/tiers/$tier")
  vals=$(yq 'select(.kind=="HelmRelease") | .spec.values' <<<"$out")
  image="$(yq '.image.repository' <<<"$vals"):$(yq '.image.tag' <<<"$vals")"
  helm template otel-collector "$chart" -n otel -f <(echo "$vals") | yq -N 'select(.kind=="ConfigMap") | .data.relay' > "$work/$tier.yaml"
  chmod 644 "$work/$tier.yaml"   # the collector image runs as non-root
  if docker run --rm -e MY_POD_IP=127.0.0.1 -v "$work:/cfg:ro" "$image" validate --config="/cfg/$tier.yaml" >"$work/out" 2>&1; then
    echo "== otel config ($tier): valid for $image"
  else
    echo "== otel config ($tier): INVALID for $image" >&2; tail -5 "$work/out" >&2; exit 1
  fi
done
