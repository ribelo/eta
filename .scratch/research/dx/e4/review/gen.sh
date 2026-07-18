#!/usr/bin/env bash
# Regenerate the review-packet case renders against the main workspace build.
# Run from the repository root inside `nix develop`:
#   bash .scratch/research/dx/e4/review/gen.sh
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(git rev-parse --show-toplevel)
dune build --root "$ROOT" lib/eta/eta.cmxa
mkdir -p _gen
ocamlfind ocamlopt \
  -I "$ROOT/_build/default/lib/eta/.eta.objs/byte" \
  -I "$ROOT/_build/default/lib/eta/.eta.objs/native" \
  "$ROOT/_build/default/lib/eta/eta.cmxa" \
  gen_renders.ml -o _gen/gen
./_gen/gen
rm -f gen_renders.cmi gen_renders.cmx gen_renders.o
