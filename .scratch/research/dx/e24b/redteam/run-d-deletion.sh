#!/usr/bin/env bash
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$here/d-surface.sh"
cp "$here/d_recipe.ml" "$tmp/d_recipe.ml"
nix develop -c dune build lib/eta/eta.cmxa
nix develop -c ocamlopt \
  -I "$repo_root/_build/default/lib/eta/.eta.objs/public_cmi" \
  -I "$repo_root/_build/default/lib/eta" \
  "$repo_root/_build/default/lib/eta/eta.cmxa" \
  "$tmp/d_recipe.ml" -o "$tmp/d-recipe.exe"
"$tmp/d-recipe.exe"
