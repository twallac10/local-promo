#!/usr/bin/env bash
# Point a tier's release.yaml at a chart digest. Touches only the OCIRepository
# document; shared values in the same file are left as they are.
set -euo pipefail
file=${1:?usage: set-digest.sh <release.yaml> <sha256:...> <version>}
digest=${2:?}; version=${3:?}
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad digest: $digest" >&2; exit 1; }
DIGEST="$digest" VERSION="$version" yq -i '
  (select(.kind == "OCIRepository") | .spec.ref.digest) = strenv(DIGEST) |
  (select(.kind == "OCIRepository") | .metadata.annotations."platform.twallac10.io/chart-version") = strenv(VERSION)
' "$file"
