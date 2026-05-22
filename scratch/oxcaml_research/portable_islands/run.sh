#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"

probe_dir="scratch/oxcaml_research/portable_islands"
out_dir="$probe_dir/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

dune build packages/effet >/dev/null

pass=0
fail=0

compile_fixture() {
  local name="$1"
  local expect="$2"
  local mode="$3"
  local packages="$4"
  local src="$probe_dir/$name.ml"
  local src_base="$probe_dir/$name"
  local safe_name="${name//\//__}"
  local exe="$out_dir/$safe_name.exe"
  local log="$out_dir/$safe_name.log"

  echo "== $name ($expect) ==" | tee -a "$out_dir/compile.out"
  set +e
  if [ "$mode" = "ox" ]; then
    ocamlfind ocamlopt -extension-universe alpha \
      -package "$packages" \
      -linkpkg \
      -I _build/default/packages/effet/.effet.objs/byte \
      _build/default/packages/effet/effet.cmxa \
      "$src" -o "$exe" >"$log" 2>&1
  else
    ocamlfind ocamlopt \
      -package "$packages" \
      -linkpkg \
      "$src" -o "$exe" >"$log" 2>&1
  fi
  local status=$?
  rm -f "$src_base.cmi" "$src_base.cmx" "$src_base.o"
  set -e
  cat "$log" >> "$out_dir/compile.out"

  if [ "$expect" = "pass" ] && [ "$status" -eq 0 ]; then
    if "$exe" | tee "$out_dir/$safe_name.out" | tee -a "$out_dir/compile.out"; then
      rm -f "$exe"
      echo "PASS expected-pass $name" | tee -a "$out_dir/compile.out"
      pass=$((pass + 1))
    else
      rm -f "$exe"
      echo "FAIL runtime $name" | tee -a "$out_dir/compile.out"
      fail=$((fail + 1))
    fi
  elif [ "$expect" = "compile-only-pass" ] && [ "$status" -eq 0 ]; then
    rm -f "$exe"
    echo "PASS expected-compile-only $name" | tee -a "$out_dir/compile.out"
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

baseline_packages="eio,eio_main,unix"
island_packages="eio,eio_main,portable,parallel,parallel.scheduler,unix"

compile_fixture baseline_ocaml_pool/cpu_pool_smoke pass mainline "$baseline_packages"
compile_fixture baseline_ocaml_pool/ordered_results_positive pass mainline "$baseline_packages"

compile_fixture oxcaml_callback_island/portable_map_positive pass ox "$island_packages"
compile_fixture oxcaml_callback_island/ordered_results_positive pass ox "$island_packages"
compile_fixture oxcaml_callback_island/all_settled_positive pass ox "$island_packages"
compile_fixture oxcaml_callback_island/atomic_capture_positive pass ox "$island_packages"
compile_fixture oxcaml_callback_island/workloads_positive pass ox "$island_packages"
compile_fixture oxcaml_callback_island/worker_die_diagnostic_positive pass ox "$island_packages"

compile_fixture oxcaml_callback_island/ref_capture_negative fail ox "$island_packages"
compile_fixture oxcaml_callback_island/eio_stream_capture_negative fail ox "$island_packages"
compile_fixture oxcaml_callback_island/runtime_capture_negative fail ox "$island_packages"
compile_fixture oxcaml_callback_island/logger_capture_negative fail ox "$island_packages"
compile_fixture oxcaml_callback_island/raw_cause_capture_negative fail ox "$island_packages"

compile_fixture use_cases/ergonomics_examples pass ox "$island_packages"
compile_fixture use_cases/busy_loop_not_preempted compile-only-pass ox "$island_packages"

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0
