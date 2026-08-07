#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$root" rev-parse --show-toplevel)"
pinned="d04d6e2bedc87ab22326af5cc03c339406177a67"
cpu="${CPU:-2}"
build="$root/_build/default/edge-compare"
results="$root/results/edges-raw.csv"
summary="$root/results/edges-summary.csv"

if [[ "$(git -C "$repo" rev-parse "$pinned")" != "$pinned" ]]; then
  echo "pinned revision is unavailable: $pinned" >&2
  exit 1
fi
if ! git -C "$repo" diff --exit-code "$pinned" -- \
    lib/signal lib/signal_map lib/signal_stream; then
  echo "production Signal sources differ from pinned revision $pinned" >&2
  exit 1
fi

export ETA_REPO="$repo"
dune build --root "$repo" @install
dune install --root "$repo" --prefix "$root/_install" \
  eta eta_observability eta_stream eta_eio eta_signal
export OCAMLPATH="$root/_install/lib${OCAMLPATH:+:$OCAMLPATH}"
dune build --root "$root" --profile release \
  edge-compare/compare_edges.exe \
  edge-compare/compare_edges_reference.exe

mkdir -p "$root/results"
echo "pair,side,name,operations,sample,wall_ns,allocated_words" >"$results"

workloads=(
  failed_retry.depth_1.position_last
  failed_retry.depth_10.position_last
  failed_retry.depth_100.position_last
  dynamic_scope_cleanup
  cancelled_contender
  observer_failure_retry
  observer_disposal
  timer_cycle
)

record() {
  local pair="$1" side="$2" executable="$3" workload="$4"
  local captured
  captured="$(mktemp)"
  taskset -c "$cpu" env EIO_BACKEND=posix \
    "$executable" --only "$workload" --samples 9 >"$captured"
  awk -F, -v OFS=, -v pair="$pair" \
    'NR > 1 { print pair,$1,$2,$4,$5,$6,$7 }' \
    "$captured" >>"$results"
  rm -f "$captured"
}

for pair in 1 2 3; do
  for workload in "${workloads[@]}"; do
    record "$pair" reference "$build/compare_edges_reference.exe" "$workload"
    record "$pair" candidate "$build/compare_edges.exe" "$workload"
  done
done

python3 "$root/summarize_edges.py" "$results" "$summary"
