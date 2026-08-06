#!/usr/bin/env python3
import csv
import statistics
import sys

with open(sys.argv[1], newline="") as source:
    rows = list(csv.DictReader(source))

print("side,name,pair,operations,median_wall_ns,median_allocated_words")
keys = sorted({(row["side"], row["name"], row["pair"]) for row in rows})
medians = {}
for side, name, pair in keys:
    group = [
        row
        for row in rows
        if row["side"] == side
        and row["name"] == name
        and row["pair"] == pair
    ]
    wall = statistics.median(float(row["wall_ns"]) for row in group)
    allocation = statistics.median(
        float(row["allocated_words"]) for row in group
    )
    medians[(side, name, pair)] = (wall, allocation)
    print(
        f"{side},{name},{pair},{group[0]['operations']},"
        f"{wall:.6f},{allocation:.6f}"
    )

for name in ["observer_failure_retry", "observer_disposal", "timer_cycle"]:
    pairs = sorted(
        pair
        for side, row_name, pair in medians
        if side == "candidate" and row_name == name
    )
    if len(pairs) != 3:
        raise SystemExit(f"{name}: expected three comparison pairs")
    wall_passes = 0
    for pair in pairs:
        candidate_wall, candidate_allocation = medians[
            ("candidate", name, pair)
        ]
        reference_wall, reference_allocation = medians[
            ("reference", name, pair)
        ]
        if candidate_allocation > reference_allocation:
            raise SystemExit(f"{name} pair {pair}: allocation gate failed")
        if candidate_wall <= reference_wall:
            wall_passes += 1
    if wall_passes < 2:
        raise SystemExit(f"{name}: wall-time gate failed")
