#!/usr/bin/env python3
"""Summarize the node lifecycle probe."""

import csv
import statistics
import sys
from collections import defaultdict

source, target = sys.argv[1:3]
groups = defaultdict(lambda: {"wall": [], "words": [], "operations": 0, "size": 0})

with open(source, newline="") as handle:
    for row in csv.DictReader(handle):
        key = (int(row["pair"]), row["name"])
        groups[key]["wall"].append(float(row["wall_ns"]))
        groups[key]["words"].append(float(row["allocated_words"]))
        groups[key]["operations"] = int(row["operations"])
        groups[key]["size"] = int(row["graph_size"])

rows = []
for (pair, name), values in sorted(groups.items()):
    rows.append(
        {
            "pair": pair,
            "name": name,
            "graph_size": values["size"],
            "operations": values["operations"],
            "median_wall_ns": statistics.median(values["wall"]),
            "median_allocated_words": statistics.median(values["words"]),
        }
    )

with open(target, "w", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=rows[0].keys(), lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
