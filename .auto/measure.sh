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
  eta_signal_map.data_change.10000
  eta_signal_map.data_change.100000
  eta_signal_map.membership_change.10000
  eta_signal_map.membership_change.100000
  eta_signal_map.child_change.10000
  eta_signal_map.child_change.100000
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
    "data_10k": 293.448466,
    "data_100k": 351.251515,
    "membership_10k": 474.784000,
    "membership_100k": 577.578000,
    "child_10k": 116.016395,
    "child_100k": 128.645411,
}

names = {
    "eta_signal_map.data_change.10000": "data_10k",
    "eta_signal_map.data_change.100000": "data_100k",
    "eta_signal_map.membership_change.10000": "membership_10k",
    "eta_signal_map.membership_change.100000": "membership_100k",
    "eta_signal_map.child_change.10000": "child_10k",
    "eta_signal_map.child_change.100000": "child_100k",
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

print(f"METRIC map_wall_ratio_geomean={geomean:.6f}")
print(f"METRIC map_worst_wall_ratio={max(ratios.values()):.6f}")
for prefix in (
    "data_10k",
    "data_100k",
    "membership_10k",
    "membership_100k",
    "child_10k",
    "child_100k",
):
    print(f"METRIC map_{prefix}_wall_ns={walls[prefix]:.6f}")
    print(f"METRIC map_{prefix}_words={words[prefix]:.6f}")

print(
    "METRIC map_data_growth_10x="
    f"{walls['data_100k'] / walls['data_10k']:.6f}"
)
print(
    "METRIC map_membership_growth_10x="
    f"{walls['membership_100k'] / walls['membership_10k']:.6f}"
)
print(
    "METRIC map_child_growth_10x="
    f"{walls['child_100k'] / walls['child_10k']:.6f}"
)
PY
