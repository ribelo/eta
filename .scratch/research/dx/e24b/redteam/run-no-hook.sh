#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
fixture="$repo_root/.scratch/research/dx/e24b/redteam"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$fixture/no_hook_positive.ml" "$tmp/no_hook_positive.ml"
cp "$fixture/no_hook_negative.ml" "$tmp/no_hook_negative.ml"

nix develop -c dune build lib/eta/eta.cmxa
nix develop -c ocamlopt \
  -I "$repo_root/_build/default/lib/eta/.eta.objs/public_cmi" \
  -I "$repo_root/_build/default/lib/eta" \
  "$repo_root/_build/default/lib/eta/eta.cmxa" \
  "$tmp/no_hook_positive.ml" -o "$tmp/no_hook_positive.exe"
"$tmp/no_hook_positive.exe"
printf '%s\n' 'positive verdict: an ordinary schedule steps with inferred no_hook'

set +e
output=$(
  nix develop -c ocamlc -c \
    -I "$repo_root/_build/default/lib/eta/.eta.objs/public_cmi" \
    "$tmp/no_hook_negative.ml" -o "$tmp/no_hook_negative.cmo" 2>&1
)
status=$?
set -e
printf '%s\n' "$output"
test "$status" -ne 0
grep -Fq 'Eta.Schedule.no_hook' <<<"$output"
grep -Fq 'unit' <<<"$output"
printf '%s\n' 'negative verdict: direct stepping rejects a tapped schedule'
