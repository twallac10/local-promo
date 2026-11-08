#!/usr/bin/env bash
# Render every app (and the canary and promoter) for one tier and check each
# container image exists for both linux/amd64 and linux/arm64, so the demo
# runs on Intel and Apple Silicon alike. Needs network and `docker manifest`.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
tier=${1:-$(first_tier)}
cache="$FLEET_DIR/.cache"
want=(amd64 arm64)

images=$(
  for repo in $(app_repos); do
    out=$(kustomize build "$WORKSPACE/$repo/tiers/$tier")
    chart=$("$FLEET_DIR/scripts/upstream-chart.sh" "$WORKSPACE/$repo" "$cache/charts")
    ns=$(yq 'select(.kind=="HelmRelease") | .metadata.namespace' <<<"$out")
    helm template x "$chart" -n "$ns" -f <(yq 'select(.kind=="HelmRelease") | .spec.values // {}' <<<"$out")
  done
  vals=$(yq 'select(.kind=="HelmRelease") | .spec.values' "$FLEET_DIR/canary/helmrelease.yaml")
  # The canary's HelmRelease disables Helm tests, so their images never run.
  helm template podinfo "$("$FLEET_DIR/scripts/upstream-chart.sh" "$FLEET_DIR/canary" "$cache/charts")" -f <(echo "$vals") --skip-tests
  cat "$FLEET_DIR/canary/loadgen.yaml" "$FLEET_DIR/promoter/deployment.yaml"
)
fail=0
for img in $(grep -oE 'image: *"?[^" ]+' <<<"$images" | sed -E 's/image: *"?//' | sort -u); do
  archs=$(docker manifest inspect "$img" 2>/dev/null \
    | jq -r '[.manifests[]? | select(.platform.os == "linux") | .platform.architecture] | unique | join(",")' 2>/dev/null || true)
  [ -n "$archs" ] || archs="single-arch or missing"
  missing=()
  for a in "${want[@]}"; do [[ ",$archs," == *",$a,"* ]] || missing+=("$a"); done
  if [ ${#missing[@]} -eq 0 ]; then printf '  ok    %-62s %s\n' "$img" "$archs"
  else printf '  FAIL  %-62s %s (missing: %s)\n' "$img" "$archs" "${missing[*]}"; fail=1; fi
done
exit $fail
