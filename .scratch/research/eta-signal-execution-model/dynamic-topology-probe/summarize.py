#!/usr/bin/env python3
import csv
import statistics
import sys

source, target = sys.argv[1], sys.argv[2]
groups = {}
with open(source, newline="") as handle:
    for row in csv.DictReader(handle):
        groups.setdefault((row["pair"], row["name"]), []).append(row)

with open(target, "w", newline="") as handle:
    fields = ["pair", "name", "graph_size", "operations", "wall_ns", "allocated_words"]
    writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    for (pair, name), rows in groups.items():
        writer.writerow({
            "pair": pair,
            "name": name,
            "graph_size": rows[0]["graph_size"],
            "operations": rows[0]["operations"],
            "wall_ns": f'{statistics.median(float(row["wall_ns"]) for row in rows):.6f}',
            "allocated_words": f'{statistics.median(float(row["allocated_words"]) for row in rows):.6f}',
        })
