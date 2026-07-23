#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
fixture="$repo_root/.scratch/research/dx/e24b/redteam"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$fixture/c_hide_hook_negative.ml" "$tmp/c_hide_hook_negative.ml"
cp "$fixture/c_pack_interpreter_positive.ml" "$tmp/c_pack_interpreter_positive.ml"

nix develop -c dune build lib/eta/eta.cmxa

set +e
output=$(
  nix develop -c ocamlc -c \
    -I "$repo_root/_build/default/lib/eta/.eta.objs/public_cmi" \
    "$tmp/c_hide_hook_negative.ml" -o "$tmp/c_hide_hook.cmo" 2>&1
)
status=$?
set -e
printf '%s\n' "$output"
test "$status" -ne 0
grep -Fq 'would escape its scope' <<<"$output"
grep -Fq 'existential type' <<<"$output"
printf '%s\n' \
  'negative verdict: a two-parameter existential cannot accept a driver-owned interpreter'

nix develop -c ocamlopt \
  -I "$repo_root/_build/default/lib/eta/.eta.objs/public_cmi" \
  -I "$repo_root/_build/default/lib/eta" \
  "$repo_root/_build/default/lib/eta/eta.cmxa" \
  "$tmp/c_pack_interpreter_positive.ml" \
  -o "$tmp/c-pack-interpreter.exe"
"$tmp/c-pack-interpreter.exe"
