#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/effect_full_gadt_probe/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

pass=0
fail=0

run_probe() {
  local name="$1"
  local expect="$2"
  local target="scratch/oxcaml_research/effect_full_gadt_probe/$name.exe"
  local log="$out_dir/$name.log"

  echo "== $name ($expect) ==" | tee -a "$out_dir/compile.out"
  set +e
  EFFET_OXCAML_RESEARCH=true dune build "$target" >"$log" 2>&1
  local status=$?
  set -e
  cat "$log" >> "$out_dir/compile.out"

  if [ "$expect" = "pass" ] && [ "$status" -eq 0 ]; then
    EFFET_OXCAML_RESEARCH=true dune exec "$target" >> "$out_dir/compile.out" 2>&1
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

run_probe candidate_a_one_gadt fail
run_probe candidate_b_split pass
run_probe candidate_b_split_negative fail
run_probe candidate_b_polyvariant_error_negative fail
run_probe candidate_c_mode_template fail

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0
