#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

dune build scratch/eta_http_research/h_s3_enforce/invariants.exe

obj_dir="_build/default/scratch/eta_http_research/h_s3_enforce/.h_s3_enforce_policy.objs/byte"
tmp_dir="${TMPDIR:-/tmp}/h-s3-enforce-negative-$$"
mkdir -p "$tmp_dir"
trap 'rm -rf "$tmp_dir"' EXIT

run_negative() {
  local name="$1"
  local src="scratch/eta_http_research/h_s3_enforce/${name}.ml"
  local out="$tmp_dir/${name}.out"

  if ocamlfind ocamlc -package tls,ca-certs,domain-name -I "$obj_dir" \
      -c "$src" -o "$tmp_dir/${name}.cmo" >"$out" 2>&1; then
    cat "$out"
    echo "FAIL expected compile failure: $name"
    exit 1
  fi

  cat "$out"
  if ! grep -Eq 'version|ciphers|label' "$out"; then
    echo "FAIL unexpected compile failure for $name"
    exit 1
  fi
  echo "PASS expected compile failure: $name"
}

run_negative negative_tls13_override
run_negative negative_dhe_cipher_override
