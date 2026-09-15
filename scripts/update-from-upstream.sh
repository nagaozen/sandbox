#!/usr/bin/env bash
# Mirror upstream main; merge upstream into the customized integration branch.
set -euo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/git-common.sh"

allow_local=false
case "${1:-}" in
  '') ;;
  --allow-local-commits) allow_local=true; shift ;;
  *) die 'Usage: update-from-upstream.sh [--allow-local-commits]' ;;
esac
(($# == 0)) || die 'Unexpected arguments.'
MINE_BRANCH=${MINE_BRANCH:-nagaozen}
init_repo
require_clean_tree
git check-ref-format "refs/heads/$MINE_BRANCH" >/dev/null
[[ "$MINE_BRANCH" != "$BASE_BRANCH" ]] || die 'MINE_BRANCH must differ from BASE_BRANCH.'
current=$(git symbolic-ref --quiet --short HEAD) || die 'Detached HEAD.'
[[ "$current" == "$MINE_BRANCH" ]] || die "Switch to $MINE_BRANCH first."

git fetch --no-tags upstream "+refs/heads/$BASE_BRANCH:refs/remotes/upstream/$BASE_BRANCH"
git fetch --no-tags origin "+refs/heads/$BASE_BRANCH:refs/remotes/origin/$BASE_BRANCH" "+refs/heads/$MINE_BRANCH:refs/remotes/origin/$MINE_BRANCH"
target=$(git rev-parse "refs/remotes/upstream/$BASE_BRANCH")
fork_tip=$(git rev-parse "refs/remotes/origin/$BASE_BRANCH")
mine_tip=$(git rev-parse "refs/remotes/origin/$MINE_BRANCH")
git merge-base --is-ancestor "$fork_tip" "$target" || die "origin/$BASE_BRANCH is not an upstream mirror. Complete the one-time migration; nothing was pushed."
if git merge-base --is-ancestor HEAD "$mine_tip"; then
  : # Equal or local behind: safe fast-forward below.
elif git merge-base --is-ancestor "$mine_tip" HEAD; then
  printf 'Unpublished local commits:\n'
  git log --oneline "$mine_tip..HEAD"
  "$allow_local" || die 'Review these commits, then rerun with --allow-local-commits to publish them.'
else
  die "Local and origin/$MINE_BRANCH diverged. Reconcile them manually; nothing was pushed."
fi
git merge-base HEAD "$target" >/dev/null || die 'No common history with upstream.'
if git merge-base --is-ancestor HEAD "$mine_tip"; then
  git merge --ff-only "$mine_tip"
fi
if ! git merge --no-edit "$target"; then
  die 'Upstream merge failed; nothing was pushed. Resolve conflicts, stage specific paths, and git commit (or git merge --abort). Then rerun with --allow-local-commits.'
fi
local_tip=$(git rev-parse HEAD)
# All-or-nothing remote ref update. No force; concurrent divergence is rejected.
git push --atomic origin "$target:refs/heads/$BASE_BRANCH" "$local_tip:refs/heads/$MINE_BRANCH"
git branch --set-upstream-to="origin/$MINE_BRANCH" "$MINE_BRANCH"
remote=$(git ls-remote --exit-code origin "refs/heads/$BASE_BRANCH" "refs/heads/$MINE_BRANCH")
[[ $(printf '%s\n' "$remote" | awk -v r="refs/heads/$BASE_BRANCH" '$2==r {print $1}') == "$target" ]] || die 'Remote base changed during verification.'
[[ $(printf '%s\n' "$remote" | awk -v r="refs/heads/$MINE_BRANCH" '$2==r {print $1}') == "$local_tip" ]] || die 'Remote integration branch changed during verification.'
printf '\nMirrored origin/%s; synchronized local and origin/%s at %s.\n' "$BASE_BRANCH" "$MINE_BRANCH" "$local_tip"
