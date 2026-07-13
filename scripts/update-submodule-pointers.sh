#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/update-submodule-pointers.sh --branch <branch> [--dry-run]

Fetches one branch from every configured submodule remote. By default it checks
out each remote tip and stages only the corresponding root gitlink changes.
Use --dry-run to report the changes without checking out or staging anything.
EOF
}

branch=""
dry_run=false
while (($#)); do
  case "$1" in
    --branch)
      (($# >= 2)) || { printf '%s\n' 'ERROR: --branch requires a value' >&2; exit 2; }
      branch="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$branch" || ! "$branch" =~ ^[A-Za-z0-9._/-]+$ ]]; then
  printf '%s\n' 'ERROR: provide a valid --branch value' >&2
  usage >&2
  exit 2
fi

root=$(git rev-parse --show-toplevel)
cd "$root"

if ! $dry_run && [[ -n "$(git status --porcelain)" ]]; then
  printf '%s\n' 'ERROR: root worktree must be clean before updating submodule pointers' >&2
  exit 1
fi

submodule_paths=()
while IFS= read -r path; do
  submodule_paths+=("$path")
done < <(git config --file .gitmodules --get-regexp '\.path$' | awk '{print $2}')
if ((${#submodule_paths[@]} == 0)); then
  printf '%s\n' 'ERROR: no submodules found in .gitmodules' >&2
  exit 1
fi

for path in "${submodule_paths[@]}"; do
  [[ -d "$root/$path" ]] || {
    printf 'ERROR: submodule is not initialized: %s\n' "$path" >&2
    exit 1
  }
  if [[ -n "$(git -C "$path" status --porcelain)" ]]; then
    printf 'ERROR: submodule worktree must be clean: %s\n' "$path" >&2
    exit 1
  fi

  git -C "$path" fetch --quiet origin "$branch"
  target=$(git -C "$path" rev-parse "origin/$branch")
  current=$(git -C "$path" rev-parse HEAD)
  if [[ "$current" == "$target" ]]; then
    printf 'UNCHANGED %s %s\n' "$path" "$target"
    continue
  fi

  if $dry_run; then
    printf 'WOULD UPDATE %s %s -> %s\n' "$path" "$current" "$target"
    continue
  fi

  git -C "$path" checkout --quiet --detach "$target"
  git add -- "$path"
  printf 'UPDATED %s %s -> %s\n' "$path" "$current" "$target"
done

if ! $dry_run; then
  printf '%s\n' 'Staged root gitlink changes:'
  git diff --cached --submodule=log --name-status -- .
fi
