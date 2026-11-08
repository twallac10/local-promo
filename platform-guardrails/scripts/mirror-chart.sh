#!/usr/bin/env bash
# Mirror the chart described by mirror/chart.yaml to oci://ghcr.io/<owner>/charts/<name>.
# Idempotent: if the version is already in GHCR it is not re-pushed (a re-push
# would mint a new digest), and the existing digest is returned.
# Needs: helm (logged in to ghcr.io), yq. Prints `version=` and `digest=` lines.
set -euo pipefail
owner=${1:?usage: mirror-chart.sh <owner> [dir-with-mirror/chart.yaml]}
cd "${2:-$(dirname "$0")/..}"

name=$(yq '.name' mirror/chart.yaml)
type=$(yq '.source.type' mirror/chart.yaml)
version=$(yq '.version' mirror/chart.yaml)
registry=${MIRROR_REGISTRY:-ghcr.io}   # override only for local testing
dest="oci://$registry/$owner/charts"
# Local test registries speak plain HTTP. (The ${a[@]+...} form keeps empty
# arrays safe under set -u on macOS bash 3.2.)
plain=(); [ "${MIRROR_PLAIN_HTTP:-}" = "1" ] && plain=(--plain-http)

digest_of() {
  # `helm show chart` does not print the digest; `helm pull` does.
  local tmp; tmp=$(mktemp -d)
  helm pull ${plain[@]+"${plain[@]}"} "$dest/$name" --version "$version" -d "$tmp" 2>&1 | sed -n 's/^Digest: //p'
  rm -rf "$tmp"
}

existing=$(digest_of || true)
if [ -n "$existing" ]; then
  echo "already mirrored: $dest/$name:$version" >&2
  echo "version=$version"; echo "digest=$existing"; exit 0
fi

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
case "$type" in
  http)  helm pull "$(yq '.source.chart' mirror/chart.yaml)" --repo "$(yq '.source.repo' mirror/chart.yaml)" --version "$version" -d "$work" ;;
  oci)   helm pull "$(yq '.source.repo' mirror/chart.yaml)/$(yq '.source.chart' mirror/chart.yaml)" --version "$version" -d "$work" ;;
  local)
    path=$(yq '.source.path' mirror/chart.yaml)
    chart_version=$(yq '.version' "$path/Chart.yaml")
    [ "$chart_version" = "$version" ] || { echo "$path/Chart.yaml version $chart_version != mirror version $version" >&2; exit 1; }
    helm package "$path" -d "$work" >&2 ;;
  *) echo "unknown source.type: $type" >&2; exit 1 ;;
esac

tgz=$(ls "$work"/*.tgz)
# helm push publishes under the chart's own name, so mirror/chart.yaml's name
# (and the OCIRepository URL) must match it, or the chart lands elsewhere.
pkg=$(basename "$tgz" "-$version.tgz")
[ "$pkg" = "$name" ] || { echo "mirror/chart.yaml name '$name' != chart name '$pkg' (helm push would publish $dest/$pkg)" >&2; exit 1; }
if ! out=$(helm push ${plain[@]+"${plain[@]}"} "$tgz" "$dest" 2>&1); then
  echo "helm push to $dest failed:" >&2; echo "$out" >&2; exit 1
fi
echo "$out" >&2
digest=$(sed -n 's/^Digest: //p' <<<"$out")
[ -n "$digest" ] || { echo "could not read digest from helm push" >&2; exit 1; }
echo "version=$version"; echo "digest=$digest"
