#!/usr/bin/env bash
# Static validation for app repos and the fleet. No cluster needed.
#
#   validate.sh <app-repo-dir>...
#
# For each app repo and each tier in tiers.yaml:
#   1. kustomize build tiers/<tier> and validate against strict CRD schemas
#   2. render the upstream chart with the merged HelmRelease values (helm
#      template) and validate the output (catches template errors and values
#      the chart's own schema rejects; it cannot catch unknown value names)
#   3. enforce the release/tier split:
#        release.yaml: only OCIRepository + HelmRelease docs; OCIRepository may
#                      only set ref.digest and the version annotation
#        tier.yaml:    only a HelmRelease doc (cannot move the chart digest)
#   4. OCI-only: no HelmRepository; OCIRepository URLs under our GHCR prefix
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
owner=${OWNER:-twallac10}
prefix="oci://ghcr.io/$owner/charts/"
cache=${CACHE_DIR:-$here/.cache}
schemas="$cache/schemas"
tiers=$(yq '.tiers[].name' "$here/tiers.yaml")
fail=0
err() { echo "  FAIL: $*" >&2; fail=$((fail + 1)); }

"$here/scripts/schemas.sh" "$schemas" >/dev/null

kc() {
  kubeconform -strict -summary -output text \
    -schema-location default \
    -schema-location "$schemas/{{.ResourceKind}}-{{.Group}}-{{.ResourceAPIVersion}}.json" "$@"
}

for repo in "$@"; do
  repo=$(cd "$repo" && pwd); name=$(basename "$repo")
  echo "== $name"
  for tier in $tiers; do
    dir="$repo/tiers/$tier"; before=$fail
    [ -d "$dir" ] || { err "$name: missing tiers/$tier"; continue; }
    out=$(mktemp)
    if ! kustomize build "$dir" > "$out"; then err "$name/$tier: kustomize build"; continue; fi
    kc "$out" >/dev/null || { kc "$out" >&2 || true; err "$name/$tier: schema"; }

    # release/tier split
    kinds=$(yq ea '[.kind] | sort | join(",")' "$dir/release.yaml")
    [ "$kinds" = "HelmRelease,OCIRepository" ] || err "$name/$tier: release.yaml must hold exactly OCIRepository + HelmRelease (got $kinds)"
    extra=$(yq 'select(.kind=="OCIRepository") | .spec | del(.ref.digest) | del(.ref | select(length==0)) | keys | join(",")' "$dir/release.yaml")
    [ -z "$extra" ] || err "$name/$tier: release.yaml OCIRepository may only set spec.ref.digest (also sets: $extra)"
    tkinds=$(yq ea '[.kind] | join(",")' "$dir/tier.yaml")
    [ "$tkinds" = "HelmRelease" ] || err "$name/$tier: tier.yaml must hold only a HelmRelease patch (got $tkinds)"
    tkeys=$(yq 'select(.kind=="HelmRelease") | .spec | keys | join(",")' "$dir/tier.yaml")
    [ "$tkeys" = "values" ] || err "$name/$tier: tier.yaml may only set spec.values (got $tkeys)"

    # OCI-only
    yq -e 'select(.kind=="HelmRepository")' "$out" >/dev/null 2>&1 && err "$name/$tier: HelmRepository is not allowed"
    while read -r url; do
      [ -z "$url" ] || [[ "$url" == "$prefix"* ]] || err "$name/$tier: OCIRepository url $url is outside $prefix"
    done < <(yq 'select(.kind=="OCIRepository") | .spec.url' "$out")

    # render the chart with the merged values
    if [ "${SKIP_RENDER:-}" != "1" ]; then
      vals=$(mktemp); yq 'select(.kind=="HelmRelease") | .spec.values // {}' "$out" > "$vals"
      chart=$("$here/scripts/upstream-chart.sh" "$repo" "$cache/charts")
      ns=$(yq 'select(.kind=="HelmRelease") | .spec.targetNamespace // .metadata.namespace' "$out")
      rel=$(yq 'select(.kind=="HelmRelease") | .spec.releaseName // .metadata.name' "$out")
      if r=$(helm template "$rel" "$chart" -n "$ns" -f "$vals" --include-crds 2>&1); then
        echo "$r" | kc -ignore-missing-schemas - >/dev/null || { echo "$r" | kc -ignore-missing-schemas - >&2 || true; err "$name/$tier: rendered chart"; }
        # Label values: the API server rejects these, kubeconform doesn't check.
        while IFS= read -r lv; do
          [ -z "$lv" ] && continue
          if [ ${#lv} -gt 63 ] || ! [[ "$lv" =~ ^([A-Za-z0-9]([-A-Za-z0-9_.]*[A-Za-z0-9])?)?$ ]]; then
            err "$name/$tier: invalid label value in rendered chart: $lv"
          fi
        done < <(echo "$r" | yq -N '.metadata.labels // {} | .[]' 2>/dev/null | sort -u)
      else
        echo "$r" | tail -5 >&2; err "$name/$tier: helm template"
      fi
      rm -f "$vals"
    fi
    rm -f "$out"
    [ "$fail" = "$before" ] && echo "  $tier ok"
  done
done
[ "$fail" -eq 0 ] || { echo "$fail failure(s)" >&2; exit 1; }
