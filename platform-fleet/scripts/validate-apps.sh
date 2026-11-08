#!/usr/bin/env bash
# Run validate.sh over every app repo in apps.yaml.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
dirs=(); for r in $(app_repos); do dirs+=("$WORKSPACE/$r"); done
exec "$FLEET_DIR/scripts/validate.sh" "${dirs[@]}"
