#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/phase2_once_finalizer_probe/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

pass=0
fail=0

run_fixture() {
  local name="$1"
  local expect="$2"
  local packages="${3:-}"
  local src="scratch/oxcaml_research/phase2_once_finalizer_probe/$name.ml"
  local base="scratch/oxcaml_research/phase2_once_finalizer_probe/$name"
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
  rm -f "$base.cmi" "$base.cmx" "$base.o"
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

run_fixture minimal_once_acquire_reuse_negative fail
run_fixture consuming_run_once_acquire_negative fail
run_fixture field_many_once_release_candidate fail
run_fixture once_ast_global_fields_positive fail
run_fixture once_ast_once_result_candidate fail
run_fixture church_once_resource_candidate pass
run_fixture public_signature_once_call_negative fail
run_fixture wrapped_once_release_negative fail
run_fixture portable_atomic_counter_positive pass portable

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0
