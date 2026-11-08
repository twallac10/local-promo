# Shared helpers for platform-fleet scripts. Source it; needs yq.
FLEET_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Folder holding a checkout of every repo side by side (the monorepo root, or
# wherever you cloned platform-fleet, platform-app-template, platform-<app>...).
WORKSPACE=${WORKSPACE:-$(cd "$FLEET_DIR/.." && pwd)}
OWNER=$(yq '.owner' "$FLEET_DIR/apps.yaml")

tiers()          { yq '.tiers[].name' "$FLEET_DIR/tiers.yaml"; }
first_tier()     { yq '.tiers[0].name' "$FLEET_DIR/tiers.yaml"; }
tier_contexts()  { yq ".tiers[] | select(.name == \"$1\") | .clusters[]" "$FLEET_DIR/tiers.yaml"; }
all_contexts()   { yq '.tiers[].clusters[]' "$FLEET_DIR/tiers.yaml"; }
app_names()      { yq '.apps[].name' "$FLEET_DIR/apps.yaml"; }
app_repos()      { yq '.apps[].repo' "$FLEET_DIR/apps.yaml"; }
app_repo()       { yq ".apps[] | select(.name == \"$1\") | .repo" "$FLEET_DIR/apps.yaml"; }
app_namespace()  { yq ".apps[] | select(.name == \"$1\") | .namespace" "$FLEET_DIR/apps.yaml"; }
# kind context "kind-tier-dev" -> kind cluster name "tier-dev"
kind_name()      { echo "${1#kind-}"; }
die()            { echo "error: $*" >&2; exit 1; }
