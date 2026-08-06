#!/usr/bin/env bash
set -euo pipefail

probe_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$probe_root" rev-parse --show-toplevel)"
samples="${SAMPLES:-9}"
pairs="${PAIRS:-3}"
cpu="${CPU:-2}"
results="$probe_root/results.csv"
summary="$probe_root/summary.csv"

cd "$repo_root"
dune build --profile release @install
export OCAMLPATH="$repo_root/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
dune build --root "$probe_root" --profile release probe.exe

exe="$probe_root/_build/default/probe.exe"
temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT

printf 'pair,name,operations,sample,wall_ns,allocated_words\n' > "$temporary"

run_one() {
  local pair="$1"
  local layer="$2"
  local kind="$3"
  local depth="$4"
  local position="$5"

  taskset -c "$cpu" "$exe" \
    --layer "$layer" \
    --kind "$kind" \
    --depth "$depth" \
    --position "$position" \
    --samples "$samples" |
    tail -n +2 |
    awk -v pair="$pair" '{ print pair "," $0 }' >> "$temporary"
}

for pair in $(seq 1 "$pairs"); do
  for layer in raw public_sync; do
    for depth in 1 10 100; do
      run_one "$pair" "$layer" successful "$depth" none
      run_one "$pair" "$layer" failed_retry "$depth" last
      if [[ "$depth" -eq 10 ]]; then
        run_one "$pair" "$layer" failed_retry "$depth" first
        run_one "$pair" "$layer" failed_retry "$depth" middle
      fi
    done
  done
done

mv "$temporary" "$results"
python3 "$probe_root/summarize.py" "$results" "$summary"
printf 'Wrote %s and %s\n' "$results" "$summary"
