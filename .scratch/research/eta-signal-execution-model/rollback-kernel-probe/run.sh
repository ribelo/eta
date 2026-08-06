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
    incremental.raw.changed.depth_1 \
    r1.changed.depth_1 \
    incremental.raw.changed.depth_10 \
    r1.changed.depth_10 \
    incremental.raw.changed.depth_100 \
    r1.changed.depth_100 \
    incremental.raw.cutoff.depth_10 \
    r1.cutoff.depth_10 \
    r1.fan_in.diamond \
    incremental.raw.changed.depth_1 \
    r2.changed.depth_1 \
    incremental.raw.changed.depth_10 \
    r2.changed.depth_10 \
    incremental.raw.changed.depth_100 \
    r2.changed.depth_100 \
    incremental.raw.cutoff.depth_10 \
    r2.cutoff.depth_10 \
    r2.fan_in.diamond \
    r1.failed_retry.depth_1 \
    r1.failed_retry.depth_10 \
    r1.failed_retry.depth_100 \
    r2.failed_retry.depth_1 \
    r2.failed_retry.depth_10 \
    r2.failed_retry.depth_100 \
    incremental.raw.changed.depth_1 \
    r1b.changed.depth_1 \
    incremental.raw.changed.depth_10 \
    r1b.changed.depth_10 \
    incremental.raw.changed.depth_100 \
    r1b.changed.depth_100 \
    incremental.raw.cutoff.depth_10 \
    r1b.cutoff.depth_10 \
    r1b.fan_in.diamond \
    r1b.failed_retry.depth_1 \
    r1b.failed_retry.depth_10 \
    r1b.failed_retry.depth_100 \
    incremental.raw.changed.depth_1 \
    r1m.changed.depth_1 \
    incremental.raw.changed.depth_10 \
    r1m.changed.depth_10 \
    incremental.raw.changed.depth_100 \
    r1m.changed.depth_100 \
    incremental.raw.cutoff.depth_10 \
    r1m.cutoff.depth_10 \
    r1m.fan_in.diamond \
    r1m.failed_retry.depth_1 \
    r1m.failed_retry.depth_10 \
    r1m.failed_retry.depth_100 \
    incremental.raw.changed.depth_1 \
    r2m.changed.depth_1 \
    incremental.raw.changed.depth_10 \
    r2m.changed.depth_10 \
    incremental.raw.changed.depth_100 \
    r2m.changed.depth_100 \
    incremental.raw.cutoff.depth_10 \
    r2m.cutoff.depth_10 \
    r2m.fan_in.diamond \
    r2m.failed_retry.depth_1 \
    r2m.failed_retry.depth_10 \
    r2m.failed_retry.depth_100 \
    incremental.raw.changed.depth_10 \
    r1w.changed.depth_10 \
    incremental.raw.changed.depth_10 \
    r1a.changed.depth_10 \
    incremental.raw.changed.depth_100 \
    r1a.changed.depth_100 \
    incremental.raw.changed.depth_1 \
    r1n.changed.depth_1 \
    incremental.raw.changed.depth_10 \
    r1n.changed.depth_10 \
    incremental.raw.changed.depth_100 \
    r1n.changed.depth_100 \
    incremental.raw.cutoff.depth_10 \
    r1n.cutoff.depth_10 \
    incremental.raw.changed.depth_1 \
    r1i.changed.depth_1 \
    incremental.raw.changed.depth_10 \
    r1i.changed.depth_10 \
    incremental.raw.changed.depth_100 \
    r1i.changed.depth_100 \
    incremental.raw.cutoff.depth_10 \
    r1i.cutoff.depth_10 \
    r1i.fan_in.diamond \
    r1i.failed_retry.depth_1 \
    r1i.failed_retry.depth_10 \
    r1i.failed_retry.depth_100 \
    incremental.raw.changed.depth_1 \
    r06.changed.depth_1 \
    incremental.raw.changed.depth_10 \
    r06.changed.depth_10 \
    incremental.raw.changed.depth_100 \
    r06.changed.depth_100 \
    incremental.raw.cutoff.depth_10 \
    r06.cutoff.depth_10
  do
    taskset -c "$cpu" "$exe" --only "$workload" --samples "$samples" |
      tail -n +2 |
      awk -v pair="$pair" '{ print pair "," $0 }' >>"$output"
  done
done

python3 "$probe_root/summarize.py" "$output" "$probe_root/summary.csv"
echo "wrote $output"
echo "wrote $probe_root/summary.csv"
