#!/usr/bin/env bash
# Bootstrap only: mirror every app chart (and the canary chart) to GHCR and
# point EVERY tier at the resulting digest, so `task up` can reach Ready before
# any promotion has happened. After this, new versions only enter through
# mirror.yaml and flow tier by tier.
#
# Needs a token that can write packages: GHCR_TOKEN, or `gh auth token` if it
# has the write:packages scope (`gh auth refresh -s write:packages`).
set -euo pipefail
source "$(dirname "$0")/lib.sh"
mirror="$WORKSPACE/platform-app-template/scripts/mirror-chart.sh"
setdigest="$WORKSPACE/platform-app-template/scripts/set-digest.sh"

if [ "${MIRROR_REGISTRY:-ghcr.io}" = ghcr.io ]; then
  token=${GHCR_TOKEN:-$(gh auth token)}
  echo "$token" | helm registry login ghcr.io -u "$(gh api user -q .login)" --password-stdin
fi

seed() { # seed <dir-with-mirror/chart.yaml> <release-files...>
  local dir=$1; shift
  local out version digest
  out=$("$mirror" "$OWNER" "$dir")
  version=$(sed -n 's/^version=//p' <<<"$out"); digest=$(sed -n 's/^digest=//p' <<<"$out")
  for f in "$@"; do "$setdigest" "$f" "$digest" "$version"; done
  printf '%-28s %s %s\n' "$(basename "$dir")" "$version" "$digest"
}

for repo in $(app_repos); do
  d="$WORKSPACE/$repo"; files=()
  for tier in $(tiers); do files+=("$d/tiers/$tier/release.yaml"); done
  seed "$d" "${files[@]}"
done
seed "$FLEET_DIR/canary" "$FLEET_DIR/canary/ocirepository.yaml"

cat <<MSG

Seeded. Next:
  1. Make each package public (one time; GitHub has no API for it):
     https://github.com/users/$OWNER/packages  ->  charts/<name>  ->  Package settings  ->  Change visibility
  2. task repos:push   (commits the digests to every repo)
MSG
