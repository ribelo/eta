#!/usr/bin/env bash
set -euo pipefail

obj_dir="_build/default/lib/http/.eta_http.objs/byte"
out_dir="${TMPDIR:-/tmp}/eta-http-negative-compile-$$"
mkdir -p "$out_dir"
trap 'rm -rf "$out_dir"' EXIT

run_negative() {
  local name="$1"
  local source="test/http/tls/${name}.ml"
  if ocamlfind ocamlc -package domain-name,ipaddr,cstruct,eio \
    -I "$obj_dir" -c "$source" -o "$out_dir/${name}.cmo" \
    >"$out_dir/${name}.out" 2>&1
  then
    cat "$out_dir/${name}.out"
    echo "FAIL expected compile failure: ${name}"
    exit 1
  else
    echo "PASS expected compile failure: ${name}"
  fi
}

run_negative negative_tls13_override
run_negative negative_dhe_cipher_override
