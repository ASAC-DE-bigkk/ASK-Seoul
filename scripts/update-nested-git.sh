#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${ROOT_DIR}"

usage() {
  cat <<'EOF'
Usage: scripts/update-nested-git.sh [submodule ...]

Fast-forwards selected submodules to the branch configured in .gitmodules.
With no arguments, preserves the deployment default and updates dags and dbt.

Examples:
  ./scripts/update-nested-git.sh
  ./scripts/update-nested-git.sh dashboard
  ./scripts/update-nested-git.sh dags dbt dashboard
EOF
}

if (($# == 1)) && [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
  exit 0
fi

requested=("$@")
if ((${#requested[@]} == 0)); then
  requested=(dags dbt)
fi

selected_paths=()
selected_branches=()

for requested_value in "${requested[@]}"; do
  if [[ "$requested_value" == -* ]]; then
    printf 'ERROR: unknown option: %s\n' "$requested_value" >&2
    usage >&2
    exit 2
  fi

  matched=false
  while read -r key path; do
    name=${key#submodule.}
    name=${name%.path}
    if [[ "$requested_value" != "$name" && "$requested_value" != "$path" ]]; then
      continue
    fi

    branch=$(git config --file .gitmodules --get "submodule.${name}.branch" || true)
    if [[ -z "$branch" || ! "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
      printf 'ERROR: valid branch is not configured for submodule %s\n' "$name" >&2
      exit 1
    fi

    selected_paths+=("$path")
    selected_branches+=("$branch")
    matched=true
    break
  done < <(git config --file .gitmodules --get-regexp '^submodule\..*\.path$')

  if ! $matched; then
    printf 'ERROR: unknown submodule: %s\n' "$requested_value" >&2
    exit 2
  fi
done

# Check every initialized worktree before changing any selected submodule.
for path in "${selected_paths[@]}"; do
  if [[ -e "$path/.git" && -n "$(git -C "$path" status --porcelain)" ]]; then
    printf 'ERROR: submodule worktree has local changes: %s\n' "$path" >&2
    exit 1
  fi
done

git submodule sync --recursive -- "${selected_paths[@]}"
git submodule update --init --recursive -- "${selected_paths[@]}"

for index in "${!selected_paths[@]}"; do
  path=${selected_paths[$index]}
  branch=${selected_branches[$index]}

  if [[ -n "$(git -C "$path" status --porcelain)" ]]; then
    printf 'ERROR: submodule worktree has local changes after initialization: %s\n' "$path" >&2
    exit 1
  fi

  printf 'Updating %s from origin/%s\n' "$path" "$branch"
  git -C "$path" fetch origin "$branch"

  if git -C "$path" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$path" checkout -q "$branch"
  else
    git -C "$path" checkout -q -b "$branch" --track "origin/$branch"
  fi

  git -C "$path" merge --ff-only "origin/$branch"
  printf 'UPDATED %s %s\n' "$path" "$(git -C "$path" rev-parse HEAD)"
done
