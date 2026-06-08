#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/eio_wrap_probe/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

pass=0
fail=0

run_fixture() {
  local name="$1"
  local expect="$2"
  local src="scratch/oxcaml_research/eio_wrap_probe/$name.ml"
  local src_base="scratch/oxcaml_research/eio_wrap_probe/$name"
  local exe="$out_dir/$name.exe"
  local log="$out_dir/$name.log"
  local packages="eio,eio_main,portable,parallel,parallel.scheduler"

  echo "== $name ($expect) ==" | tee -a "$out_dir/compile.out"
  set +e
  ocamlfind ocamlopt -extension-universe alpha -package "$packages" -linkpkg "$src" -o "$exe" >"$log" 2>&1
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

run_fixture eio_wrap_positive pass
run_fixture parallel_inside_eio_positive pass
run_fixture switch_local_fork_negative fail
run_fixture runtime_create_local_switch_negative fail
run_fixture switch_escape_wrapped_negative fail
run_fixture fiber_portable_ref_capture_negative fail
run_fixture stream_payload_negative fail
run_fixture stream_parallel_wrapped_negative fail

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0
