#!/usr/bin/env bash
set -euo pipefail
ROOT="${1:-$(git rev-parse --show-toplevel)}"
PPX="$ROOT/_build/install/default/lib/ppx_eta/ppx.exe"
ETA_CMI="$ROOT/_build/default/lib/eta/.eta.objs/byte"
cd "$(dirname "$0")"
for base in hand let_eta attr; do
  echo "===== $base ====="
  ocamlfind ocamlc -I "$ETA_CMI" -ppx "$PPX --as-ppx" -c "$base.mli" "$base.ml"
  echo "ok"
done
rm -f *.cmi *.cmo
echo "mli invariance: all three forms compile against the same signature"
