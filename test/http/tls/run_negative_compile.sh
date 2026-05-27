#!/usr/bin/env bash
set -euo pipefail

dune build lib/http/tls

obj_dir="_build/default/lib/http/tls/.http_tls.objs/byte"

run_negative() {
  local name="$1"
  local source="test/http/tls/${name}.ml"
  if ocamlfind ocamlc -package domain-name,ipaddr,cstruct,eio \
    -I "$obj_dir" -c "$source" >/tmp/eta-http-${name}.out 2>&1
  then
    cat "/tmp/eta-http-${name}.out"
    echo "FAIL expected compile failure: ${name}"
    exit 1
  else
    echo "PASS expected compile failure: ${name}"
  fi
}

run_negative negative_tls13_override
run_negative negative_dhe_cipher_override
