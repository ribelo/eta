#!/usr/bin/env bash
set -euo pipefail

processes=${PROCESSES:-3}
samples=${SAMPLES:-9}
cpu=${CPU:-2}
output_dir=${1:-bench/signal_compare/results}
exe=_build/default/bench/signal_compare/compare.exe

workloads=(
  incremental.changed.depth_1
  eta_signal.changed.depth_1
  incremental.changed.depth_10
  eta_signal.changed.depth_10
  incremental.changed.depth_100
  eta_signal.changed.depth_100
  incremental.cutoff.depth_10
  eta_signal.cutoff.depth_10
  incremental.dynamic.switch
  eta_signal.dynamic.switch
  incr_map.data_change.10000
  eta_signal_map.data_change.10000
  incr_map.data_change.100000
  eta_signal_map.data_change.100000
  incr_map.membership_change.10000
  eta_signal_map.membership_change.10000
  incr_map.membership_change.100000
  eta_signal_map.membership_change.100000
  incr_map.child_change.10000
  eta_signal_map.child_change.10000
  incr_map.child_change.100000
  eta_signal_map.child_change.100000
)

mkdir -p "$output_dir"
nix develop -c dune build --profile release bench/signal_compare/compare.exe

for process in $(seq 1 "$processes"); do
  output="$output_dir/run${process}.csv"
  printf 'name,operations,sample,wall_ns,allocated_words\n' >"$output"
  for workload in "${workloads[@]}"; do
    taskset -c "$cpu" "$exe" --only "$workload" --samples "$samples" |
      tail -n +2 >>"$output"
  done
done
