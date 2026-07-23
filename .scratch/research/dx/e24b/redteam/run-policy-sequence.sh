#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
fixture="$repo_root/.scratch/research/dx/e24b/redteam/policy_sequence.ml"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$fixture" "$tmp/policy_sequence.ml"

nix develop -c dune build lib/eta/eta.cmxa
nix develop -c ocamlopt \
  -I "$repo_root/_build/default/lib/eta/.eta.objs/public_cmi" \
  -I "$repo_root/_build/default/lib/eta" \
  "$repo_root/_build/default/lib/eta/eta.cmxa" \
  "$tmp/policy_sequence.ml" -o "$tmp/policy-sequence.exe"
"$tmp/policy-sequence.exe"
