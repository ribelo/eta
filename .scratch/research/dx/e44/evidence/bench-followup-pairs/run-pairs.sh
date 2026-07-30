#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
before="${BEFORE_EXE:-$root/.scratch/e44-followup-baseline/_build/default/bench/runtime_observability/runtime_observability.exe}"
after="${AFTER_EXE:-$root/_build/default/bench/runtime_observability/runtime_observability.exe}"
out="${OUT_DIR:-$root/.scratch/research/dx/e44/evidence/bench-followup-pairs}"

test -x "$before"
test -x "$after"
mkdir -p "$out"

run_one() {
  local executable="$1"
  local output="$2"
  EIO_BACKEND=posix "$executable" --samples 3 > "$output"
}

for pair in $(seq -w 1 15); do
  if ((10#$pair % 2 == 1)); then
    run_one "$before" "$out/before-$pair.jsonl"
    run_one "$after" "$out/after-$pair.jsonl"
  else
    run_one "$after" "$out/after-$pair.jsonl"
    run_one "$before" "$out/before-$pair.jsonl"
  fi
done
