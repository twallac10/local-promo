#!/usr/bin/env bash
# Create and/or sync the GitHub repos from the local folders in $WORKSPACE.
#
#   repos.sh create   create missing repos (app repos from the template), then sync
#   repos.sh push     sync every local folder to main of its repo
#   repos.sh shape    check every app folder has the template's shape
#
# Sync = clone, mirror the folder over the clone, commit, push. Flux bootstrap
# output (clusters/*/flux-system) in platform-fleet is never overwritten.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
TEMPLATE=platform-app-template
OTHERS=(platform-fleet platform-promoter)

exists() { gh repo view "$OWNER/$1" --json name >/dev/null 2>&1; }

sync_repo() {
  local repo=$1 src="$WORKSPACE/$1" tmp
  [ -d "$src" ] || { echo "skip $repo: no folder $src"; return 0; }
  tmp=$(mktemp -d)
  gh repo clone "$OWNER/$repo" "$tmp/r" -- -q 2>/dev/null || { mkdir -p "$tmp/r"; git -C "$tmp/r" init -q -b main; git -C "$tmp/r" remote add origin "https://github.com/$OWNER/$repo.git"; }
  rsync -a --delete --exclude .git --exclude .cache --exclude 'clusters/*/flux-system/' "$src/" "$tmp/r/"
  git -C "$tmp/r" add -A
  if git -C "$tmp/r" diff --cached --quiet; then
    echo "$repo: up to date"
  else
    git -C "$tmp/r" commit -qm "${SYNC_MESSAGE:-sync from workspace}"
    git -C "$tmp/r" push -q origin HEAD:main
    echo "$repo: pushed"
  fi
  rm -rf "$tmp"
}

create() {
  if ! exists "$TEMPLATE"; then
    gh repo create "$OWNER/$TEMPLATE" --public --description "Shape every platform app repo is created from"
    sync_repo "$TEMPLATE"
  fi
  gh api -X PATCH "repos/$OWNER/$TEMPLATE" -F is_template=true >/dev/null
  for repo in $(app_repos); do
    if ! exists "$repo"; then
      gh repo create "$OWNER/$repo" --public --template "$OWNER/$TEMPLATE" --description "Platform app deployment repo"
      # Generation from a template is async; wait for main to exist.
      for _ in $(seq 1 30); do gh api "repos/$OWNER/$repo/branches/main" >/dev/null 2>&1 && break; sleep 2; done
    fi
  done
  for repo in "${OTHERS[@]}"; do
    exists "$repo" || gh repo create "$OWNER/$repo" --public
  done
  push
}

push() {
  for repo in "$TEMPLATE" $(app_repos) "${OTHERS[@]}"; do sync_repo "$repo"; done
  tag_promoter
}

# App repos pin the reusable workflow by tag; create the tag for VERSION if
# it doesn't exist yet. Tags are never moved: bump VERSION for a new release.
tag_promoter() {
  local v; v=$(cat "$WORKSPACE/platform-promoter/VERSION")
  if gh api "repos/$OWNER/platform-promoter/git/ref/tags/$v" >/dev/null 2>&1; then
    echo "platform-promoter: tag $v exists"; return 0
  fi
  local sha; sha=$(gh api "repos/$OWNER/platform-promoter/git/ref/heads/main" -q .object.sha)
  gh api "repos/$OWNER/platform-promoter/git/refs" -f ref="refs/tags/$v" -f sha="$sha" >/dev/null
  echo "platform-promoter: tagged $v at ${sha:0:7}"
}

# Every app folder must have the template's files (plus chart/ for apps built
# from source), and the shared files must be byte-identical to the template.
shape() {
  local t="$WORKSPACE/$TEMPLATE" fail=0 repo f
  local shared=(.github/workflows/mirror.yaml .github/workflows/promotion.yaml .gitignore base/kustomization.yaml scripts/mirror-chart.sh scripts/set-digest.sh)
  for tier in $(tiers); do shared+=("tiers/$tier/kustomization.yaml"); done
  for repo in $(app_repos); do
    local d="$WORKSPACE/$repo"
    [ -d "$d" ] || { echo "MISSING $repo"; fail=1; continue; }
    diff <(cd "$t" && find . -type f -not -path './.git/*' | sort) \
         <(cd "$d" && find . -type f -not -path './.git/*' -not -path './chart/*' | sort) >/dev/null \
      || { echo "SHAPE $repo: file set differs from template:"; diff <(cd "$t" && find . -type f -not -path './.git/*' | sort) <(cd "$d" && find . -type f -not -path './.git/*' -not -path './chart/*' | sort) | sed 's/^/    /'; fail=1; }
    for f in "${shared[@]}"; do
      cmp -s "$t/$f" "$d/$f" || { echo "DRIFT $repo: $f differs from template"; fail=1; }
    done
    for tier in $(tiers | tail -n +2); do
      cmp -s "$d/tiers/$(first_tier)/release.yaml" "$d/tiers/$tier/release.yaml" \
        || echo "note  $repo: tiers/$tier/release.yaml differs from $(first_tier) (fine mid-promotion)"
    done
  done
  # Callers must pin the reusable workflow at the promoter's released version.
  local v; v=$(cat "$WORKSPACE/platform-promoter/VERSION")
  grep -q "guardrails.yaml@$v\$" "$t/.github/workflows/promotion.yaml" && grep -q "promoter-ref: $v\$" "$t/.github/workflows/promotion.yaml" \
    || { echo "PIN   promotion.yaml must use guardrails.yaml@$v and promoter-ref: $v (platform-promoter/VERSION)"; fail=1; }
  [ $fail -eq 0 ] && echo "all app repos match the template shape"
  return $fail
}

case "${1:-}" in
  create) create ;;
  push) push ;;
  shape) shape ;;
  *) die "usage: repos.sh create|push|shape" ;;
esac
