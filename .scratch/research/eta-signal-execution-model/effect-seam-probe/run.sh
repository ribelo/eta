#!/usr/bin/env bash
set -euo pipefail

probe_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$probe_root" rev-parse --show-toplevel)"
samples="${SAMPLES:-9}"
cpu="${CPU:-2}"
results="$probe_root/results.csv"
summary="$probe_root/summary.csv"

cd "$repo_root"
dune build --profile release @install
export OCAMLPATH="$repo_root/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
dune build --root "$probe_root" --profile release probe.exe

exe="$probe_root/_build/default/probe.exe"
taskset -c "$cpu" "$exe" --check

first=1
: > "$results"
for pair in 1 2 3; do
  export PAIR="$pair"
  for depth in 1 10 100; do
    for layer in raw effect driver_sync public_sync public_eio; do
      if [[ "$first" -eq 1 ]]; then
        taskset -c "$cpu" "$exe" \
          --layer "$layer" --depth "$depth" --samples "$samples" \
          >> "$results"
        first=0
      else
        taskset -c "$cpu" "$exe" \
          --layer "$layer" --depth "$depth" --samples "$samples" |
          tail -n +2 >> "$results"
      fi
    done
  done

  for layer in deep_claim_sync cursor_sync; do
    taskset -c "$cpu" "$exe" \
      --layer "$layer" --depth 1 --samples "$samples" |
      tail -n +2 >> "$results"
  done

  for layer in candidate reference; do
    taskset -c "$cpu" "$exe" \
      --edge "$layer" --samples "$samples" |
      tail -n +2 >> "$results"
  done
done

python3 "$probe_root/summarize.py" < "$results" > "$summary"
cat "$summary"
