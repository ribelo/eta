#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/concurrency_model/h3_hardening/t8_no_eio_leakage/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

dune build packages/effet >/dev/null

pass=0
fail=0

compile_fixture() {
  local name="$1"
  local expect="$2"
  local src="scratch/oxcaml_research/concurrency_model/h3_hardening/t8_no_eio_leakage/$name.ml"
  local src_base="scratch/oxcaml_research/concurrency_model/h3_hardening/t8_no_eio_leakage/$name"
  local exe="$out_dir/$name.exe"
  local log="$out_dir/$name.log"
  local packages="eio,eio_main,portable,parallel,parallel.scheduler,unix"

  echo "== $name ($expect) ==" | tee -a "$out_dir/compile.out"
  set +e
  ocamlfind ocamlopt -extension-universe alpha \
    -package "$packages" \
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

compile_fixture portable_replacements_positive pass
compile_fixture switch_capture_negative fail
compile_fixture promise_capture_negative fail
compile_fixture stream_capture_negative fail
compile_fixture cancel_capture_negative fail
compile_fixture clock_capture_negative fail
compile_fixture stdenv_capture_negative fail
compile_fixture tracer_capture_negative fail
compile_fixture logger_capture_negative fail
compile_fixture meter_capture_negative fail
compile_fixture raw_cause_capture_negative fail
compile_fixture runtime_capture_negative fail

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0

