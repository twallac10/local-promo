#!/usr/bin/env bash
# Print a local path to the chart described by <app-repo>/mirror/chart.yaml,
# fetched from upstream (lint only; clusters never pull from upstream).
set -euo pipefail
repo=${1:?}; cache=${2:?}
m="$repo/mirror/chart.yaml"
type=$(yq '.source.type' "$m"); version=$(yq '.version' "$m"); name=$(yq '.name' "$m")
if [ "$type" = local ]; then
  # Render a package whose version carries build metadata, the way Flux sees
  # an OCI chart (0.1.1+<digest>), so labels built from .Chart.Version are
  # checked for '+' (invalid in label values).
  out="$cache/local-$name"; rm -rf "$out"; mkdir -p "$out"
  helm package "$repo/$(yq '.source.path' "$m")" --version "$version+lintbuild" -d "$out" >/dev/null
  echo "$out/$(ls "$out" | head -1)"; exit 0
fi
dest="$cache/$name-$version"
if [ ! -d "$dest" ]; then
  # Pull into a temp dir and move it in place, so a failed download never
  # leaves an empty cache entry behind.
  mkdir -p "$cache"; tmp=$(mktemp -d "$cache/.pull.XXXXXX")
  if [ "$type" = http ]; then
    helm pull "$(yq '.source.chart' "$m")" --repo "$(yq '.source.repo' "$m")" --version "$version" --untar -d "$tmp" >&2 || { rm -rf "$tmp"; exit 1; }
  else
    helm pull "$(yq '.source.repo' "$m")/$(yq '.source.chart' "$m")" --version "$version" --untar -d "$tmp" >&2 || { rm -rf "$tmp"; exit 1; }
  fi
  mv "$tmp" "$dest"
fi
echo "$dest/$(ls "$dest" | head -1)"
