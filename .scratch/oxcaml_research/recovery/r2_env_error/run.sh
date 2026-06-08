#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"

probe_dir="scratch/oxcaml_research/recovery/r2_env_error"
out_dir="$probe_dir/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

dune build packages/effet >/dev/null

pass=0
fail=0

compile_fixture() {
  local name="$1"
  local expect="$2"
  local src="$probe_dir/$name.ml"
  local src_base="$probe_dir/$name"
  local exe="$out_dir/$name.exe"
  local log="$out_dir/$name.log"

  echo "== $name ($expect) ==" | tee -a "$out_dir/compile.out"
  set +e
  ocamlfind ocamlopt -extension-universe alpha \
    -package portable,parallel,parallel.scheduler \
    -linkpkg \
    -I _build/default/packages/effet/.effet.objs/byte \
    _build/default/packages/effet/effet.cmxa \
    "$src" -o "$exe" >"$log" 2>&1
  local status=$?
  rm -f "$src_base.cmi" "$src_base.cmx" "$src_base.o"
  set -e
  cat "$log" >> "$out_dir/compile.out"

  if [ "$expect" = "pass" ] && [ "$status" -eq 0 ]; then
    if "$exe" | tee "$out_dir/$name.out" | tee -a "$out_dir/compile.out"; then
      rm -f "$exe"
      echo "PASS expected-pass $name" | tee -a "$out_dir/compile.out"
      pass=$((pass + 1))
    else
      rm -f "$exe"
      echo "FAIL runtime $name" | tee -a "$out_dir/compile.out"
      fail=$((fail + 1))
    fi
  elif [ "$expect" = "fail" ] && [ "$status" -ne 0 ]; then
    rm -f "$exe"
    echo "PASS expected-fail $name" | tee -a "$out_dir/compile.out"
    pass=$((pass + 1))
  else
    rm -f "$exe"
    echo "FAIL expectation-mismatch $name status=$status" | tee -a "$out_dir/compile.out"
    fail=$((fail + 1))
  fi
}

compile_fixture env_a_closed_records_positive pass
compile_fixture env_b_phantom_tuple_positive pass
compile_fixture env_c_closed_object_negative fail
compile_fixture error_a_closed_polyvariant_positive pass
compile_fixture error_b_closed_record_positive pass
compile_fixture error_c_cause_portable_positive pass
compile_fixture negative_open_polyvariant_error fail
compile_fixture negative_raw_cause_error fail
compile_fixture negative_ref_capture fail

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0
