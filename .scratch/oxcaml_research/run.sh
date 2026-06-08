#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

pass=0
fail=0

run_fixture() {
  local name="$1"
  local expect="$2"
  local packages="${3:-}"
  local src="scratch/oxcaml_research/fixtures/$name.ml"
  local src_base="scratch/oxcaml_research/fixtures/$name"
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
    echo "PASS expected-fail $name" | tee -a "$out_dir/compile.out"
    pass=$((pass + 1))
  else
    rm -f "$exe"
    echo "FAIL expectation-mismatch $name status=$status" | tee -a "$out_dir/compile.out"
    fail=$((fail + 1))
  fi
}

run_dune_fixture() {
  local name="$1"
  local expect="$2"
  local target="scratch/oxcaml_research/effet_portable_probe/$name.exe"
  local log="$out_dir/$name.log"

  echo "== $name ($expect) [dune] ==" | tee -a "$out_dir/compile.out"
  set +e
  EFFET_OXCAML_RESEARCH=true dune build "$target" >"$log" 2>&1
  local status=$?
  set -e
  cat "$log" >> "$out_dir/compile.out"

  if [ "$expect" = "pass" ] && [ "$status" -eq 0 ]; then
    EFFET_OXCAML_RESEARCH=true dune exec "$target" >>"$out_dir/compile.out" 2>&1
    echo "PASS expected-pass $name" | tee -a "$out_dir/compile.out"
    pass=$((pass + 1))
  elif [ "$expect" = "fail" ] && [ "$status" -ne 0 ]; then
    echo "PASS expected-fail $name" | tee -a "$out_dir/compile.out"
    pass=$((pass + 1))
  else
    echo "FAIL expectation-mismatch $name status=$status" | tee -a "$out_dir/compile.out"
    fail=$((fail + 1))
  fi
}

run_fixture resource_same_domain_positive pass
run_fixture resource_ref_portable_negative fail
run_fixture resource_stdlib_atomic_portable_negative fail
run_fixture resource_portable_atomic_positive pass portable
run_fixture resource_capsule_isolated_positive pass capsule
run_fixture resource_capsule_external_refresh_negative fail capsule
run_fixture supervisor_local_positive pass
run_fixture supervisor_local_return_negative fail
run_fixture supervisor_local_ref_negative fail
run_fixture effect_ast_plain_positive pass
run_fixture effect_ast_portable_capture_negative fail
run_fixture effect_ast_atomic_capture_positive pass
run_fixture cause_portable_positive pass
run_fixture cause_closure_negative fail
run_fixture eio_fiber_smoke pass eio_main
run_fixture parallel_scheduler_smoke pass parallel,parallel.scheduler
run_fixture parallel_ref_capture_negative fail parallel,parallel.scheduler
run_fixture resource_portable_auto_parallel_positive pass portable,parallel,parallel.scheduler
run_fixture stream_portable_sink_parallel_positive pass portable,parallel,parallel.scheduler
run_fixture stream_eio_queue_parallel_negative fail eio_main,parallel,parallel.scheduler
run_fixture effet_redesigned_portable_positive pass portable,parallel,parallel.scheduler
run_fixture effet_redesigned_portable_negative fail portable
run_fixture acquire_release_once_positive pass
run_fixture acquire_release_once_negative fail
run_fixture switch_escape_local_negative fail eio_main

run_dune_fixture effet_real_t_portable_smoke pass
run_dune_fixture effet_real_t_portable_negative fail

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0
