#!/usr/bin/env bash
# Push a feat/* branch to the fork and open (or find) its upstream PR.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/git-common.sh"
args=()
while (($#)); do
  case "$1" in
    --draft|--fill|--fill-first|--fill-verbose) args+=("$1"); shift ;;
    --title|--body|--body-file)
      (($# >= 2)) || die "Missing value for $1"
      args+=("$1" "$2"); shift 2 ;;
    *) die "Unsupported option: $1" ;;
  esac
done
if ((${#args[@]} == 0)); then args=(--fill); fi
init_repo
require_command gh
require_clean_tree
branch=$(git symbolic-ref --quiet --short HEAD) || die 'Detached HEAD: switch to a feat/* branch.'
[[ "$branch" == feat/?* && "$branch" != "$BASE_BRANCH" && "$branch" != "${MINE_BRANCH:-nagaozen}" ]] || die 'Upstream PRs must come from feat/*, never main or the integration branch.'
gh auth status --hostname github.com >/dev/null 2>&1 || die 'Authenticate first: gh auth login --hostname github.com --scopes repo,workflow'
git fetch --no-tags upstream "+refs/heads/$BASE_BRANCH:refs/remotes/upstream/$BASE_BRANCH"
base="refs/remotes/upstream/$BASE_BRANCH"
git merge-base "$base" HEAD >/dev/null || die 'Feature branch and upstream have no common history.'
[[ $(git rev-list --count "$base..HEAD") -gt 0 ]] || die 'No feature commits to propose.'
if git diff --quiet "$base...HEAD"; then die 'No file changes to propose.'; fi
printf 'Proposed commits (start upstream-bound features from origin/main, not nagaozen):\n'
git log --oneline "$base..HEAD"
if ! git merge-base --is-ancestor "$base" HEAD; then
  printf 'Note: branch does not contain latest upstream/%s; GitHub will check mergeability.\n' "$BASE_BRANCH" >&2
fi
head="${FORK_REPO%%/*}:$branch"
existing=$(gh pr list --repo "$UPSTREAM_REPO" --base "$BASE_BRANCH" \
  --head "$head" --state open --json url --jq '.[0].url // empty')
git push --set-upstream origin "HEAD:refs/heads/$branch"
if [[ -n "$existing" ]]; then
  printf '\nUpdated existing PR: %s\n' "$existing"
else
  gh pr create --repo "$UPSTREAM_REPO" --base "$BASE_BRANCH" --head "$head" "${args[@]}"
fi
