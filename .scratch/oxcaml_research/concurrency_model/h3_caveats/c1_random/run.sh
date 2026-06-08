#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../../.." && pwd)"
cd "$root"

probe_dir="scratch/oxcaml_research/concurrency_model/h3_caveats/c1_random"
out_dir="$probe_dir/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

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

policy_reject_random_float() {
  local name="$1"
  local src="$probe_dir/$name.ml"
  local src_base="$probe_dir/$name"
  local exe="$out_dir/$name.exe"
  local log="$out_dir/$name.log"

  echo "== $name (policy-fail) ==" | tee -a "$out_dir/compile.out"
  set +e
  ocamlfind ocamlopt -extension-universe alpha \
    -package portable,parallel,parallel.scheduler \
    -linkpkg \
    "$src" -o "$exe" >"$log" 2>&1
  local status=$?
  rm -f "$src_base.cmi" "$src_base.cmx" "$src_base.o" "$exe"
  set -e
  cat "$log" >> "$out_dir/compile.out"

  if grep -q "Random.float" "$src"; then
    echo "compiler_status=$status policy_rejected=Random.float" | tee -a "$out_dir/compile.out"
    echo "PASS expected-policy-fail $name" | tee -a "$out_dir/compile.out"
    pass=$((pass + 1))
  else
    echo "FAIL policy-missed $name" | tee -a "$out_dir/compile.out"
    fail=$((fail + 1))
  fi
}

compile_fixture object_capability_probe fail
compile_fixture portable_rng_token_positive pass
compile_fixture coordinator_delays_positive pass
compile_fixture coordinator_delays_finite_negative pass
policy_reject_random_float global_random_negative
compile_fixture captured_random_state_negative fail
compile_fixture mutable_ref_rng_negative fail

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0
