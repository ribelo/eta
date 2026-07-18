#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
fixture="$repo_root/.scratch/research/dx/e24/contract-blocker"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$fixture"/contract.ml "$fixture"/contract.mli "$fixture"/use.ml "$tmp"/

set +e
output=$(
  nix develop -c bash -lc \
    "cd '$tmp' && ocamlc -c contract.mli && ocamlc -c contract.ml && ocamlc -c use.ml" \
    2>&1
)
status=$?
set -e

printf '%s\n' "$output"
test "$status" -ne 0
grep -Fq '?max_concurrent:int -> int list Contract.effect' <<<"$output"
grep -Fq 'This function application is partial' <<<"$output"
printf '%s\n' 'verdict: exact optional-last contract makes ordinary omission partial'
