#!/usr/bin/env bash
# Delete every tier cluster in tiers.yaml.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
for ctx in $(all_contexts); do kind delete cluster --name "$(kind_name "$ctx")"; done
