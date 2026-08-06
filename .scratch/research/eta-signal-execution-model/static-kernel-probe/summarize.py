#!/usr/bin/env python3
"""Summarize the static kernel probe. This file is prototype tooling."""

import csv
import statistics
import sys
from collections import defaultdict


source, target = sys.argv[1:3]
samples = defaultdict(lambda: {"wall": [], "words": [], "operations": 0})

with open(source, newline="") as handle:
    for row in csv.DictReader(handle):
        key = (int(row["pair"]), row["name"])
        samples[key]["wall"].append(float(row["wall_ns"]))
        samples[key]["words"].append(float(row["allocated_words"]))
        samples[key]["operations"] = int(row["operations"])

rows = []
for (pair, name), values in sorted(samples.items()):
    rows.append(
        {
            "pair": pair,
            "name": name,
            "operations": values["operations"],
            "median_wall_ns": statistics.median(values["wall"]),
            "median_allocated_words": statistics.median(values["words"]),
        }
    )

with open(target, "w", newline="") as handle:
    writer = csv.DictWriter(
        handle, fieldnames=rows[0].keys(), lineterminator="\n"
    )
    writer.writeheader()
    writer.writerows(rows)
