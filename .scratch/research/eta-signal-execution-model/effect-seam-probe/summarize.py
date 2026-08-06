#!/usr/bin/env python3

import csv
import statistics
import sys

rows = list(csv.DictReader(sys.stdin))
writer = csv.writer(sys.stdout, lineterminator="\n")
writer.writerow(
    ["name", "pair", "operations", "median_wall_ns", "median_allocated_words"]
)

groups = {}
for row in rows:
    groups.setdefault((row["name"], row["pair"], row["operations"]), []).append(row)

for (name, pair, operations), samples in groups.items():
    writer.writerow(
        [
            name,
            pair,
            operations,
            f"{statistics.median(float(row['wall_ns']) for row in samples):.6f}",
            f"{statistics.median(float(row['allocated_words']) for row in samples):.6f}",
        ]
    )
