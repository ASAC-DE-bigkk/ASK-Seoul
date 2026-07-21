#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

git_configure_identity() {
  git -C "$1" config user.name "ASK Seoul Test"
  git -C "$1" config user.email "ask-seoul-test@localhost.invalid"
}

create_child() {
  name=$1
  source_path="$TEST_ROOT/${name}-source"
  remote_path="$TEST_ROOT/${name}.git"

  git init -q -b main "$source_path"
  git_configure_identity "$source_path"
  printf 'v1\n' >"$source_path/version.txt"
  git -C "$source_path" add version.txt
  git -C "$source_path" commit -q -m "v1"
  git clone -q --bare "$source_path" "$remote_path"
  git -C "$source_path" remote add origin "$remote_path"
}

publish_version() {
  name=$1
  version=$2
  source_path="$TEST_ROOT/${name}-source"

  printf '%s\n' "$version" >"$source_path/version.txt"
  git -C "$source_path" add version.txt
  git -C "$source_path" commit -q -m "$version"
  git -C "$source_path" push -q origin main
}

for child in dags dbt dashboard; do
  create_child "$child"
done

parent="$TEST_ROOT/parent"
git init -q -b dev "$parent"
git_configure_identity "$parent"
mkdir -p "$parent/scripts"
cp "$SOURCE_ROOT/scripts/update-nested-git.sh" "$parent/scripts/update-nested-git.sh"
chmod +x "$parent/scripts/update-nested-git.sh"

for child in dags dbt dashboard; do
  git -C "$parent" -c protocol.file.allow=always submodule add -q \
    "$TEST_ROOT/${child}.git" "$child"
  git -C "$parent" config --file .gitmodules "submodule.${child}.branch" main
done
git -C "$parent" add .
git -C "$parent" commit -q -m "initial submodules"

for child in dags dbt dashboard; do
  publish_version "$child" v2
done

(
  cd "$parent"
  ./scripts/update-nested-git.sh >/dev/null
)

[[ "$(<"$parent/dags/version.txt")" == "v2" ]]
[[ "$(<"$parent/dbt/version.txt")" == "v2" ]]
[[ "$(<"$parent/dashboard/version.txt")" == "v1" ]]

(
  cd "$parent"
  ./scripts/update-nested-git.sh dashboard >/dev/null
)
[[ "$(<"$parent/dashboard/version.txt")" == "v2" ]]

printf 'local change\n' >>"$parent/dashboard/version.txt"
publish_version dashboard v3
if (
  cd "$parent"
  ./scripts/update-nested-git.sh dashboard >/dev/null 2>&1
); then
  printf '%s\n' 'FAIL: dirty dashboard update unexpectedly succeeded' >&2
  exit 1
fi
grep -q '^local change$' "$parent/dashboard/version.txt"

printf '%s\n' 'PASS: selective nested repository updates and dirty-worktree guard'
