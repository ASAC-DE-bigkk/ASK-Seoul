#!/usr/bin/env bash
set -euo pipefail

root=$(git rev-parse --show-toplevel)
cd "$root"

submodule_paths=()
while IFS= read -r path; do
  submodule_paths+=("$path")
done < <(git config --file .gitmodules --get-regexp '\.path$' | awk '{print $2}')
if ((${#submodule_paths[@]} == 0)); then
  printf '%s\n' 'FAIL: no submodules found in .gitmodules' >&2
  exit 1
fi

for path in "${submodule_paths[@]}"; do
  [[ -d "$root/$path" ]] || {
    printf 'FAIL: submodule is not initialized: %s\n' "$path" >&2
    exit 1
  }
  index_oid=$(git ls-files --stage -- "$path" | awk '$1 == 160000 {print $2}')
  worktree_oid=$(git -C "$path" rev-parse HEAD)
  if [[ -z "$index_oid" ]]; then
    printf 'FAIL: root index has no gitlink for %s\n' "$path" >&2
    exit 1
  fi
  if [[ "$index_oid" != "$worktree_oid" ]]; then
    printf 'FAIL: pointer mismatch for %s: index=%s worktree=%s\n' "$path" "$index_oid" "$worktree_oid" >&2
    exit 1
  fi
  printf 'PASS: %s -> %s\n' "$path" "$worktree_oid"
done

printf '%s\n' 'PASS: all submodule pointers match the checked-out commits.'
