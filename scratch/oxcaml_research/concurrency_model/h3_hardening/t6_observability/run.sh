#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/concurrency_model/h3_hardening/t6_observability/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

dune build packages/effet >/dev/null

pass=0
fail=0

compile_fixture() {
  local name="$1"
  local expect="$2"
  local packages="$3"
  local src="scratch/oxcaml_research/concurrency_model/h3_hardening/t6_observability/$name.ml"
  local src_base="scratch/oxcaml_research/concurrency_model/h3_hardening/t6_observability/$name"
  local exe="$out_dir/$name.exe"
  local log="$out_dir/$name.log"

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

compile_fixture observability_positive pass portable,parallel,parallel.scheduler,unix
compile_fixture tracer_collector_capture_negative fail portable,parallel,parallel.scheduler
compile_fixture closure_attribute_negative fail portable,parallel,parallel.scheduler

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0

