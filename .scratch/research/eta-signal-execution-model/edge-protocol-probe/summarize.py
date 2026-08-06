#!/usr/bin/env python3
import csv
import statistics
import sys

with open(sys.argv[1], newline="") as source:
    rows = list(csv.DictReader(source))

print("side,name,pair,operations,median_wall_ns,median_allocated_words")
keys = sorted({(row["side"], row["name"], row["pair"]) for row in rows})
for side, name, pair in keys:
    group = [
        row
        for row in rows
        if row["side"] == side
        and row["name"] == name
        and row["pair"] == pair
    ]
    print(
        f"{side},{name},{pair},{group[0]['operations']},"
        f"{statistics.median(float(row['wall_ns']) for row in group):.6f},"
        f"{statistics.median(float(row['allocated_words']) for row in group):.6f}"
    )
