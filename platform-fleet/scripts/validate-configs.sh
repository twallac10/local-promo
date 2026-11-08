#!/usr/bin/env bash
# Validate rendered configs with the pinned images themselves: the OTel
# Collector (`otelcol validate`, catches components the distribution doesn't
# include) and Prometheus (`promtool check config`, incl. rule files). These
# otherwise only fail at runtime. Needs docker; skipped with a note without it.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
if ! docker info >/dev/null 2>&1; then echo "== image config checks: skipped (docker not running)"; exit 0; fi
work=$(mktemp -d); chmod 755 "$work"; trap 'rm -rf "$work"' EXIT
# OTel Collector: `validate` catches components the distribution lacks.
repo="$WORKSPACE/platform-otel-collector"
[ -d "$repo" ] && chart=$("$FLEET_DIR/scripts/upstream-chart.sh" "$repo" "$FLEET_DIR/.cache/charts")
for tier in $( [ -d "$repo" ] && tiers ); do
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

# Prometheus: promtool checks the rendered prometheus.yml and its rule files.
repo="$WORKSPACE/platform-prometheus"
[ -d "$repo" ] && chart=$("$FLEET_DIR/scripts/upstream-chart.sh" "$repo" "$FLEET_DIR/.cache/charts")
for tier in $( [ -d "$repo" ] && tiers ); do
  out=$(kustomize build "$repo/tiers/$tier")
  vals=$(yq 'select(.kind=="HelmRelease") | .spec.values' <<<"$out")
  image="quay.io/prometheus/prometheus:$(yq '.server.image.tag' <<<"$vals")"
  cfg="$work/prom-$tier"; mkdir -p "$cfg"; chmod 755 "$cfg"
  rendered=$(helm template prometheus "$chart" -n prometheus -f <(echo "$vals"))
  for k in $(yq -N 'select(.kind=="ConfigMap" and .metadata.name=="prometheus") | .data | keys | .[]' <<<"$rendered"); do
    yq -N "select(.kind==\"ConfigMap\" and .metadata.name==\"prometheus\") | .data.\"$k\"" <<<"$rendered" > "$cfg/$k"
  done
  chmod 644 "$cfg"/*
  if docker run --rm -v "$cfg:/etc/config:ro" --entrypoint promtool "$image" check config /etc/config/prometheus.yml >"$work/out" 2>&1; then
    echo "== prometheus config ($tier): valid for $image"
  else
    echo "== prometheus config ($tier): INVALID for $image" >&2; tail -8 "$work/out" >&2; exit 1
  fi
done
