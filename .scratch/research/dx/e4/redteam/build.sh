#!/usr/bin/env bash
# Build and run the E4 compact-rendering red-team probe against the MAIN
# workspace build (not the switch-installed eta, which may be stale).
# Run from the repository root inside `nix develop`:
#   bash .scratch/research/dx/e4/redteam/build.sh
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$(git rev-parse --show-toplevel)
dune build --root "$ROOT" lib/eta/eta.cmxa
mkdir -p _probe
ocamlfind ocamlopt \
  -I "$ROOT/_build/default/lib/eta/.eta.objs/byte" \
  -I "$ROOT/_build/default/lib/eta/.eta.objs/native" \
  "$ROOT/_build/default/lib/eta/eta.cmxa" \
  probe_compact_monster.ml -o _probe/probe
./_probe/probe | tee output.txt
