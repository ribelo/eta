#!/usr/bin/env bash
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
prototype="$repo/.scratch/prototypes/eta-crux-performance-gates"

nix develop -c bash -euo pipefail -c '
  prototype="$1"
  dune build --root "$prototype" @runtest
  dune exec --root "$prototype" ./main.exe -- --samples 31
' _ "$prototype"
