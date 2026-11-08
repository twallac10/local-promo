#!/usr/bin/env bash
# demo:reset — put every repo back to the workspace state (the seeded
# baseline) and close open demo/promotion PRs, so a scenario can run again.
# Pushes straight to main: needs admin (branch protection doesn't enforce admins).
set -euo pipefail
source "$(dirname "$0")/../lib.sh"
for repo in $(app_repos); do
  gh pr list --repo "$OWNER/$repo" --state open --json number,headRefName \
    -q '.[] | select(.headRefName | test("^(promote|demo)/")) | .number' \
    | while read -r n; do gh pr close "$n" --repo "$OWNER/$repo" --delete-branch >/dev/null && echo "$repo: closed #$n"; done
done
SYNC_MESSAGE="demo reset" "$FLEET_DIR/scripts/repos.sh" push
echo "Repos reset. Flux picks it up within a minute; the PromotionGates re-gate the restored releases."
