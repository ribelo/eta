#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../../.." && pwd)"
cd "$root"

out_dir="scratch/oxcaml_research/concurrency_model/h3_hardening/t1_inbox/results"
mkdir -p "$out_dir"
: > "$out_dir/compile.out"

pass=0
fail=0

run_fixture() {
  local name="$1"
  local src="scratch/oxcaml_research/concurrency_model/h3_hardening/t1_inbox/$name.ml"
  local src_base="scratch/oxcaml_research/concurrency_model/h3_hardening/t1_inbox/$name"
  local exe="$out_dir/$name.exe"
  local log="$out_dir/$name.log"

  echo "== $name ==" | tee -a "$out_dir/compile.out"
  set +e
  ocamlfind ocamlopt -extension-universe alpha -package portable -linkpkg "$src" -o "$exe" >"$log" 2>&1
  local status=$?
  rm -f "$src_base.cmi" "$src_base.cmx" "$src_base.o"
  set -e
  cat "$log" >> "$out_dir/compile.out"

  if [ "$status" -eq 0 ]; then
    if "$exe" >> "$out_dir/compile.out" 2>&1; then
      rm -f "$exe"
      echo "PASS $name" | tee -a "$out_dir/compile.out"
      pass=$((pass + 1))
    else
      rm -f "$exe"
      echo "FAIL runtime $name" | tee -a "$out_dir/compile.out"
      fail=$((fail + 1))
    fi
  else
    rm -f "$exe"
    echo "FAIL compile $name status=$status" | tee -a "$out_dir/compile.out"
    fail=$((fail + 1))
  fi
}

run_fixture phase_separated_positive
run_fixture capacity_positive
run_fixture close_positive
run_fixture two_producer_race_negative
run_fixture mixed_push_drain_negative
run_fixture push_after_close_negative

echo "summary: pass=$pass fail=$fail" | tee -a "$out_dir/compile.out"
test "$fail" -eq 0

