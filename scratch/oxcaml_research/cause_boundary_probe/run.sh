#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/cause_boundary_probe/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

pass=0
fail=0

run_fixture() {
  local name="$1"
  local expect="$2"
  local packages="${3:-}"
  local src="scratch/oxcaml_research/cause_boundary_probe/$name.ml"
  local src_base="scratch/oxcaml_research/cause_boundary_probe/$name"
  local exe="$out_dir/$name.exe"
  local log="$out_dir/$name.log"

  echo "== $name ($expect) ==" | tee -a "$out_dir/compile.out"
  set +e
  if [ -n "$packages" ]; then
    ocamlfind ocamlopt -extension-universe alpha -package "$packages" -linkpkg "$src" -o "$exe" >"$log" 2>&1
  else
    ocamlopt -extension-universe alpha "$src" -o "$exe" >"$log" 2>&1
  fi
  local status=$?
  rm -f "$src_base.cmi" "$src_base.cmx" "$src_base.o"
  set -e
  cat "$log" >> "$out_dir/compile.out"

  if [ "$expect" = "pass" ] && [ "$status" -eq 0 ]; then
    "$exe" >> "$out_dir/compile.out" 2>&1
    rm -f "$exe"
    echo "PASS expected-pass $name" | tee -a "$out_dir/compile.out"
    pass=$((pass + 1))
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

run_fixture raw_exn_positive pass parallel,parallel.scheduler
run_fixture raw_exn_fcm_negative pass parallel,parallel.scheduler
run_fixture materialized_positive pass portable,parallel,parallel.scheduler
run_fixture materialized_closure_negative fail
run_fixture typed_defect_positive pass portable,parallel,parallel.scheduler
run_fixture typed_defect_negative fail
run_fixture explicit_conversion_positive pass portable,parallel,parallel.scheduler
run_fixture explicit_conversion_negative fail parallel,parallel.scheduler

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0
