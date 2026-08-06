#!/usr/bin/env bash
set -euo pipefail

probe_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
samples="${SAMPLES:-9}"
pairs="${PAIRS:-3}"
cpu="${CPU:-2}"
output="${OUTPUT:-$probe_root/results.csv}"

cd "$probe_root"
dune build --root "$probe_root" --profile release probe.exe
exe="$probe_root/_build/default/probe.exe"

"$exe" --check

echo "pair,name,operations,sample,wall_ns,allocated_words" >"$output"
for pair in $(seq 1 "$pairs"); do
  for workload in \
    plan.changed.depth_1 \
    plan.changed.depth_10 \
    plan.changed.depth_100 \
    plan.cutoff.depth_10 \
    incremental.raw.changed.depth_1 \
    raw.changed.depth_1 \
    incremental.raw.changed.depth_10 \
    raw.changed.depth_10 \
    incremental.raw.changed.depth_100 \
    raw.changed.depth_100 \
    incremental.raw.cutoff.depth_10 \
    raw.cutoff.depth_10 \
    raw.fan_in.diamond
  do
    taskset -c "$cpu" "$exe" --only "$workload" --samples "$samples" |
      tail -n +2 |
      awk -v pair="$pair" '{ print pair "," $0 }' >>"$output"
  done
done

python3 "$probe_root/summarize.py" "$output" "$probe_root/summary.csv"
echo "wrote $output"
echo "wrote $probe_root/summary.csv"
