# Helpers for the demo scenarios. Source after ../lib.sh. Needs gh, jq, yq, kubectl.
DEMO_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }

preflight() {
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated"
  for ctx in $(all_contexts); do
    kubectl --context "$ctx" -n promoter get promotiongates >/dev/null 2>&1 \
      || die "$ctx: no PromotionGates (run task up, and wait for task status to be Ready)"
  done
}

# wait_until <timeout-seconds> <description> <command...>: poll every 10s.
wait_until() {
  local timeout=$1 desc=$2; shift 2
  local end=$(( $(date +%s) + timeout ))
  printf '  waiting: %s ' "$desc"
  until "$@" >/dev/null 2>&1; do
    if [ "$(date +%s)" -ge "$end" ]; then echo; die "timed out after ${timeout}s: $desc"; fi
    printf '.'; sleep 10
  done
  echo " ok"
}

# clone_repo <repo> → prints a temp checkout dir.
clone_repo() {
  local d; d=$(mktemp -d)
  gh repo clone "$OWNER/$1" "$d" -- -q
  git -C "$d" config user.name "demo"; git -C "$d" config user.email "demo@users.noreply.github.com"
  echo "$d"
}

# open_pr <dir> <branch> <title> <body> [label] → prints the PR URL. Auto-merge on.
open_pr() {
  local dir=$1 branch=$2 title=$3 body=$4 label=${5:-}
  git -C "$dir" push -q -f origin "HEAD:refs/heads/$branch"
  local args=(--repo "$(git -C "$dir" remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')" --base main --head "$branch" --title "$title" --body "$body")
  [ -n "$label" ] && args+=(--label "$label")
  local url; url=$(gh pr create "${args[@]}")
  gh pr merge "$url" --auto --squash >/dev/null 2>&1 || info "(could not enable auto-merge on $url)"
  echo "$url"
}

pr_state()  { gh pr view "$1" --json state -q .state; }
is_merged() { [ "$(pr_state "$1")" = MERGED ]; }

# newest PR in repo whose head starts with prefix and was created after the demo started
find_pr() {
  gh pr list --repo "$OWNER/$1" --state all --limit 30 --json url,headRefName,createdAt \
    | jq -r --arg p "$2" --arg t "$DEMO_START" '[.[] | select((.headRefName | startswith($p)) and .createdAt >= $t)] | sort_by(.createdAt) | last | .url // empty'
}
has_pr() { [ -n "$(find_pr "$1" "$2")" ]; }

# PromotionGate state on a cluster: "<phase>|<release commit>|<message>"
pg_state() { kubectl --context "$1" -n promoter get promotiongate "$2" -o jsonpath='{.status.phase}|{.status.release.commit}|{.status.message}' 2>/dev/null; }

# pg_is <ctx> <app> <commit> <phase...>: gate is in one of the phases for that release commit
pg_is() {
  local ctx=$1 app=$2 commit=$3; shift 3
  local st; st=$(pg_state "$ctx" "$app"); local phase=${st%%|*} rest=${st#*|}; local c=${rest%%|*}
  [ "$c" = "$commit" ] || return 1
  for p in "$@"; do [ "$phase" = "$p" ] && return 0; done
  return 1
}

# commit on main that last changed a tier's release.yaml
release_commit() { gh api "repos/$OWNER/$1/commits?sha=main&path=tiers/$2/release.yaml&per_page=1" -q '.[0].sha'; }

show_gates() {
  local app=$1
  for tier in $(tiers); do
    for ctx in $(tier_contexts "$tier"); do
      printf '  %-4s %-16s %s\n' "$tier" "$ctx" "$(pg_state "$ctx" "$app" | awk -F'|' '{printf "%-9s %s", $1, $3}')"
    done
  done
}
