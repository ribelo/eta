#!/usr/bin/env python3
import csv
import json
from pathlib import Path
from statistics import median

HERE = Path(__file__).resolve().parent


def load(side: str, pair: int):
    rows = {}
    path = HERE / f"{side}-{pair:02d}.jsonl"
    for line in path.read_text().splitlines():
        row = json.loads(line)
        rows[(row["name"], row["metric"])] = row["samples"]
    return rows


before = [load("before", pair) for pair in range(1, 16)]
after = [load("after", pair) for pair in range(1, 16)]
if any(set(left) != set(right) for left, right in zip(before, after)):
    raise SystemExit("before/after benchmark rows differ")

names = sorted(name for name, metric in before[0] if metric == "wall_ns")
columns = [
    "name",
    "before_wall_median_ns",
    "after_wall_median_ns",
    "pooled_wall_delta_pct",
    "pair_delta_min_pct",
    "pair_delta_median_pct",
    "pair_delta_max_pct",
    "positive_pairs",
    "before_allocated_words",
    "after_allocated_words",
    "allocation_delta_words",
]

with (HERE / "summary.csv").open("w", newline="") as output:
    writer = csv.DictWriter(output, fieldnames=columns, lineterminator="\n")
    writer.writeheader()
    for name in names:
        key = (name, "wall_ns")
        before_wall = [sample for pair in before for sample in pair[key]]
        after_wall = [sample for pair in after for sample in pair[key]]
        before_median = median(before_wall)
        after_median = median(after_wall)
        pair_deltas = []
        for before_pair, after_pair in zip(before, after):
            left = median(before_pair[key])
            right = median(after_pair[key])
            pair_deltas.append((right / left - 1.0) * 100.0)
        before_alloc = median(
            sample
            for pair in before
            for sample in pair[(name, "allocated_words")]
        )
        after_alloc = median(
            sample
            for pair in after
            for sample in pair[(name, "allocated_words")]
        )
        writer.writerow(
            {
                "name": name,
                "before_wall_median_ns": f"{before_median:.6f}",
                "after_wall_median_ns": f"{after_median:.6f}",
                "pooled_wall_delta_pct": f"{(after_median / before_median - 1.0) * 100.0:.3f}",
                "pair_delta_min_pct": f"{min(pair_deltas):.3f}",
                "pair_delta_median_pct": f"{median(pair_deltas):.3f}",
                "pair_delta_max_pct": f"{max(pair_deltas):.3f}",
                "positive_pairs": sum(delta > 0.0 for delta in pair_deltas),
                "before_allocated_words": f"{before_alloc:.0f}",
                "after_allocated_words": f"{after_alloc:.0f}",
                "allocation_delta_words": f"{after_alloc - before_alloc:.0f}",
            }
        )
