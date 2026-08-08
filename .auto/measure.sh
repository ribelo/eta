#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export EIO_BACKEND="${EIO_BACKEND:-posix}"

cpu=${CPU:-2}
samples=${SAMPLES:-1}
exe=_build/default/bench/signal_compare/compare.exe
results=$(mktemp)
build_log=$(mktemp)
trap 'rm -f "$results" "$build_log"' EXIT

if ! nix develop -c dune build --profile release \
  bench/signal_compare/compare.exe >"$build_log" 2>&1; then
  tail -80 "$build_log"
  exit 1
fi

workloads=(
  eta_signal.changed.depth_1
  eta_signal.changed.depth_10
  eta_signal.changed.depth_100
  eta_signal.cutoff.depth_10
  eta_signal.dynamic.switch
)

for workload in "${workloads[@]}"; do
  taskset -c "$cpu" "$exe" --only "$workload" --samples "$samples" |
    awk -F, -v name="$workload" '$1 == name { print }' >>"$results"
done

python3 - "$results" "$samples" <<'PY'
import csv
import math
import statistics
import sys

path = sys.argv[1]
sample_count = int(sys.argv[2])

references = {
    "changed_1": 53.892009,
    "changed_10": 127.957776,
    "changed_100": 1059.433089,
    "cutoff_10": 32.418910,
    "dynamic": 145.031947,
}

names = {
    "eta_signal.changed.depth_1": "changed_1",
    "eta_signal.changed.depth_10": "changed_10",
    "eta_signal.changed.depth_100": "changed_100",
    "eta_signal.cutoff.depth_10": "cutoff_10",
    "eta_signal.dynamic.switch": "dynamic",
}

rows = {prefix: [] for prefix in names.values()}
with open(path, newline="") as handle:
    for row in csv.reader(handle):
        if len(row) != 5 or row[0] not in names:
            raise SystemExit(f"unexpected benchmark row: {row!r}")
        rows[names[row[0]]].append((float(row[3]), float(row[4])))

walls = {}
words = {}
for prefix, samples in rows.items():
    if len(samples) != sample_count:
        raise SystemExit(
            f"{prefix}: expected {sample_count} samples, got {len(samples)}"
        )
    walls[prefix] = statistics.median(sample[0] for sample in samples)
    words[prefix] = statistics.median(sample[1] for sample in samples)

ratios = {prefix: walls[prefix] / references[prefix] for prefix in walls}
geomean = math.exp(sum(math.log(ratio) for ratio in ratios.values()) / len(ratios))

print(f"METRIC signal_wall_ratio_geomean={geomean:.6f}")
print(f"METRIC signal_worst_wall_ratio={max(ratios.values()):.6f}")
for prefix in (
    "changed_1",
    "changed_10",
    "changed_100",
    "cutoff_10",
    "dynamic",
):
    print(f"METRIC signal_{prefix}_wall_ns={walls[prefix]:.6f}")
    print(f"METRIC signal_{prefix}_words={words[prefix]:.6f}")

print(
    "METRIC signal_changed_growth_1_to_10="
    f"{walls['changed_10'] / walls['changed_1']:.6f}"
)
print(
    "METRIC signal_changed_growth_10_to_100="
    f"{walls['changed_100'] / walls['changed_10']:.6f}"
)
PY
