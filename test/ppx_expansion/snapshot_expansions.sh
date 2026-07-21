#!/usr/bin/env bash
set -euo pipefail

ROOT="${DUNE_SOURCEROOT:-$(cd "$1" && pwd)}"
PPX="$ROOT/_build/install/default/lib/ppx_eta/ppx.exe"

for src in cases/*.ml; do
  echo "===== ${src#cases/} ====="
  ocamlfind ocamlc -ppx "$PPX --as-ppx" -dsource -c "$src" 2>&1
  rm -f "${src%.ml}.cmo" "${src%.ml}.cmi"
done

for src in rejections/*.ml; do
  echo "===== ${src#rejections/} (rejected) ====="
  if output=$(ocamlfind ocamlc -ppx "$PPX --as-ppx" -dsource -c "$src" 2>&1); then
    rm -f "${src%.ml}.cmo" "${src%.ml}.cmi"
    echo "expected PPX rejection, but compilation succeeded" >&2
    exit 1
  fi
  printf '%s\n' "$output"
  rm -f "${src%.ml}.cmo" "${src%.ml}.cmi"
done
