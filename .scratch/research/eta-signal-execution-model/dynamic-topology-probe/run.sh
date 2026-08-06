#!/usr/bin/env bash
set -euo pipefail

probe_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(git -C "$probe_root" rev-parse --show-toplevel)"
samples="${SAMPLES:-9}"
pairs="${PAIRS:-3}"
cpu="${CPU:-2}"
results="$probe_root/results.csv"

cd "$repo_root"
dune build --profile release @install
export OCAMLPATH="$repo_root/_build/install/default/lib${OCAMLPATH:+:$OCAMLPATH}"
dune build --root "$probe_root" --profile release probe.exe
exe="$probe_root/_build/default/probe.exe"

"$exe" --check
printf 'pair,name,graph_size,operations,sample,wall_ns,allocated_words\n' > "$results"

workloads=(
  incremental.raw.dynamic.switch
  capsule.raw.dynamic.switch
  journal.raw.dynamic.switch
  eta_reference.dynamic_scope_cleanup
  incremental.raw.keyed.data.10000
  capsule.raw.keyed.data.10000
  incremental.raw.keyed.data.100000
  capsule.raw.keyed.data.100000
  incremental.raw.keyed.membership.10000
  capsule.raw.keyed.membership.10000
  incremental.raw.keyed.membership.100000
  capsule.raw.keyed.membership.100000
  incremental.raw.keyed.child.10000
  capsule.raw.keyed.child.10000
  incremental.raw.keyed.child.100000
  capsule.raw.keyed.child.100000
)

for pair in $(seq 1 "$pairs"); do
  for workload in "${workloads[@]}"; do
    taskset -c "$cpu" "$exe" --only "$workload" --samples "$samples" |
      tail -n +2 |
      awk -v pair="$pair" '{ print pair "," $0 }' >> "$results"
  done
done

python3 "$probe_root/summarize.py" "$results" "$probe_root/summary.csv"
printf 'Wrote %s\n' "$results"
printf 'Wrote %s\n' "$probe_root/summary.csv"
