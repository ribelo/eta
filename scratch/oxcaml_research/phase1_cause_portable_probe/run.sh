#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/phase1_cause_portable_probe/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

pass=0
fail=0

compile_fixture() {
  local name="$1"
  local expect="$2"
  local src="scratch/oxcaml_research/phase1_cause_portable_probe/$name.ml"
  local src_base="scratch/oxcaml_research/phase1_cause_portable_probe/$name"
  local exe="$out_dir/$name.exe"
  local log="$out_dir/$name.log"

  echo "== $name ($expect) ==" | tee -a "$out_dir/compile.out"
  dune build packages/effet >/dev/null

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

compile_fixture portable_cause_parallel_positive pass
compile_fixture raw_cause_parallel_negative fail
compile_fixture portable_payload_ref_negative fail

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0
