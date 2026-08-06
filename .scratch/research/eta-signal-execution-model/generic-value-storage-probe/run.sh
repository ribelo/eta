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

echo "pair,name,graph_size,operations,sample,wall_ns,allocated_words" >"$output"

record_workload() {
  local actual="$1"
  local reported="$2"
  taskset -c "$cpu" "$exe" --only "$actual" --samples "$samples" |
    tail -n +2 |
    awk -F, -v OFS=, -v pair="$pair" -v reported="$reported" \
      '{ $1 = reported; print pair, $0 }' >>"$output"
}

for pair in $(seq 1 "$pairs"); do
  for depth in 1 10 100; do
    case $(( pair % 3 )) in
      1) candidates=(a b c) ;;
      2) candidates=(b c a) ;;
      0) candidates=(c a b) ;;
    esac
    record_workload "control.int.changed.depth_$depth" \
      "control.int.changed.depth_$depth"
    for candidate in "${candidates[@]}"; do
      record_workload "incremental.raw.int.changed.depth_$depth" \
        "incremental.$candidate.raw.int.changed.depth_$depth"
      record_workload "$candidate.int.changed.depth_$depth" \
        "$candidate.int.changed.depth_$depth"
    done
    for candidate in "${candidates[@]}"; do
      record_workload "incremental.raw.boxed_old.changed.depth_$depth" \
        "incremental.$candidate.raw.boxed_old.changed.depth_$depth"
      record_workload "$candidate.boxed_old.changed.depth_$depth" \
        "$candidate.boxed_old.changed.depth_$depth"
    done
  done

  record_workload control.boxed_old.old_ref_store \
    control.boxed_old.old_ref_store
  record_workload control.boxed_young.construct \
    control.boxed_young.construct
  record_workload control.boxed_young.old_ref_store \
    control.boxed_young.old_ref_store
  for candidate in "${candidates[@]}"; do
    record_workload "$candidate.boxed_young.changed.depth_1" \
      "$candidate.boxed_young.changed.depth_1"
  done
done

python3 "$probe_root/summarize.py" "$output" "$probe_root/summary.csv"
echo "wrote $output"
echo "wrote $probe_root/summary.csv"
