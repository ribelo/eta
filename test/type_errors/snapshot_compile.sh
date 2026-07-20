#!/usr/bin/env bash
# Compile every cases/*.ml and concatenate the compiler output.
# supervisor_* cases compile against the workspace eta cmi; ppx_* and sql_*
# cases run the workspace ppx_eta driver. Invoked by the dune rule in this
# directory with $1 = project root; cwd is the dune build dir.
set -uo pipefail
# Dune sets DUNE_SOURCEROOT and INSIDE_DUNE (absolute source/build roots) in
# rule actions; fall back to resolving $1 for manual runs.
ROOT="${DUNE_SOURCEROOT:-$(cd "$1" && pwd)}"
BUILD="${INSIDE_DUNE:-$ROOT/_build/default}"
ETA_CMI="$BUILD/lib/eta/.eta.objs/byte"
PPX="$ROOT/_build/install/default/lib/ppx_eta/ppx.exe"

for src in cases/*.ml; do
  name=${src#cases/}
  echo "===== $name ====="
  case "$name" in
    ppx_* | sql_*)
      # Include eta cmi so body type errors under sugar can resolve Effect.t
      # when cases use the real library; stub-only cases ignore the path.
      ocamlfind ocamlc -I "$ETA_CMI" -ppx "$PPX --as-ppx" -c "$src" 2>&1
      ;;
    *)
      ocamlfind ocamlc -I "$ETA_CMI" -c "$src" 2>&1
      ;;
  esac
  echo "exit=$?"
  rm -f "${src%.ml}.cmo" "${src%.ml}.cmi"
done
