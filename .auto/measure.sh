#!/usr/bin/env bash
set -euo pipefail

cpu=${CPU:-2}
exe=_build/default/bench/signal_compare/compare.exe

nix develop -c dune build --profile release bench/signal_compare/compare.exe >/dev/null

measure() {
  local workload=$1
  local prefix=$2
  local rows wall words
  rows=$(taskset -c "$cpu" "$exe" --only "$workload" --samples 3 | tail -n 3)
  wall=$(cut -d, -f4 <<<"$rows" | sort -n | sed -n '2p')
  words=$(cut -d, -f5 <<<"$rows" | sort -n | sed -n '2p')
  printf 'METRIC %s_wall_ns=%s\n' "$prefix" "$wall"
  printf 'METRIC %s_words=%s\n' "$prefix" "$words"
}

measure eta_signal_map.child_change.10000 signal_map_child_10k
measure eta_signal.changed.depth_1 signal_depth_1
measure eta_signal.changed.depth_100 signal_depth_100
measure eta_signal_map.membership_change.10000 signal_map_membership_10k
