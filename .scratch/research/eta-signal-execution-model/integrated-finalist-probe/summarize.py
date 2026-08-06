#!/usr/bin/env python3
"""Reduce each frozen nine-sample process to its median."""

import csv
import statistics
import sys
from collections import defaultdict

source, target = sys.argv[1:3]
groups = defaultdict(lambda: {"wall": [], "words": [], "operations": set()})
with open(source, newline="") as handle:
    for row in csv.DictReader(handle):
        key = (int(row["pair"]), row["boundary"], row["side"], row["workload"])
        groups[key]["wall"].append(float(row["wall_ns"]))
        groups[key]["words"].append(float(row["allocated_words"]))
        groups[key]["operations"].add(int(row["operations"]))

rows = []
for (pair, boundary, side, workload), values in sorted(groups.items()):
    if len(values["wall"]) != 9:
        raise SystemExit(f"{pair}/{boundary}/{side}/{workload}: expected nine samples")
    if len(values["operations"]) != 1:
        raise SystemExit(f"{pair}/{boundary}/{side}/{workload}: calibration changed in-process")
    rows.append(
        {
            "pair": pair,
            "boundary": boundary,
            "side": side,
            "workload": workload,
            "operations": next(iter(values["operations"])),
            "median_wall_ns": statistics.median(values["wall"]),
            "median_allocated_words": statistics.median(values["words"]),
        }
    )

with open(target, "w", newline="") as handle:
    fields = list(rows[0]) if rows else [
        "pair", "boundary", "side", "workload", "operations",
        "median_wall_ns", "median_allocated_words"
    ]
    writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
