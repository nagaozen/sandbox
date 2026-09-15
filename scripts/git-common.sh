#!/usr/bin/env bash
# Shared helpers; sourced by the two entry-point scripts.
set -euo pipefail

UPSTREAM_REPO=agent-infra/sandbox
FORK_REPO=nagaozen/sandbox
BASE_BRANCH=${BASE_BRANCH:-main}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

check_remote() {
  local remote=$1 repo=$2 url
  url=$(git remote get-url "$remote") || die "Add remote: git remote add $remote https://github.com/$repo.git"
  case "$url" in
    "https://github.com/$repo"|"https://github.com/$repo.git"|"git@github.com:$repo"|"git@github.com:$repo.git"|"ssh://git@github.com/$repo"|"ssh://git@github.com/$repo.git") ;;
    *) die "Remote '$remote' must point to github.com/$repo; found $url" ;;
  esac
  # Check every push URL too, so pushes cannot silently go elsewhere.
  while IFS= read -r url; do
    case "$url" in
      "https://github.com/$repo"|"https://github.com/$repo.git"|"git@github.com:$repo"|"git@github.com:$repo.git"|"ssh://git@github.com/$repo"|"ssh://git@github.com/$repo.git") ;;
      *) die "Unexpected push URL for '$remote': $url" ;;
    esac
  done < <(git remote get-url --push --all "$remote")
}

init_repo() {
  require_command git
  local root
  root=$(git rev-parse --show-toplevel) || die 'Run this script from inside the sandbox repository.'
  cd "$root"
  git check-ref-format "refs/heads/$BASE_BRANCH" >/dev/null || die 'Invalid BASE_BRANCH.'
  check_remote upstream "$UPSTREAM_REPO"
  check_remote origin "$FORK_REPO"
  for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
    [[ ! -e $(git rev-parse --git-path "$state") ]] || die "Finish or abort the current Git operation ($state) first."
  done
}

require_clean_tree() {
  [[ -z $(git status --porcelain --untracked-files=normal) ]] || die 'Working tree is not clean. Commit or stash your changes (including untracked files) first.'
}
