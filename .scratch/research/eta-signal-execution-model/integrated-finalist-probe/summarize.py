#!/usr/bin/env python3
"""Verify and reduce the frozen three-pair performance comparison."""

import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

source, target = map(Path, sys.argv[1:3])
workload_table = Path(sys.argv[3]) if len(sys.argv) > 3 else source.parent.parent / "performance-workloads.tsv"

allocation_limits = {
    "changed.depth_1": (100.0, False),
    "changed.depth_10": (100.0, False),
    "changed.depth_100": (100.0, False),
    "cutoff.depth_10": (100.0, False),
    "dynamic.switch": (51.6, True),
    "map.data_change.10000": (216.0, True),
    "map.data_change.100000": (273.6, True),
    "map.membership_change.10000": (412.2, True),
    "map.membership_change.100000": (520.2, True),
    "map.child_change.10000": (93.6, True),
    "map.child_change.100000": (122.4, True),
}


def workload_names(path):
    names = []
    with path.open() as handle:
        for line in handle:
            if not line.strip() or line.startswith("#"):
                continue
            names.append(line.rstrip("\n").split("\t", 1)[0])
    return names


names = workload_names(workload_table)
if set(names) != set(allocation_limits):
    raise SystemExit("performance-workloads.tsv and allocation limits disagree")

groups = defaultdict(lambda: {"wall": [], "words": [], "operations": set(), "samples": []})
with source.open(newline="") as handle:
    for row in csv.DictReader(handle):
        key = (int(row["pair"]), row["boundary"], row["side"], row["workload"])
        groups[key]["wall"].append(float(row["wall_ns"]))
        groups[key]["words"].append(float(row["allocated_words"]))
        groups[key]["operations"].add(int(row["operations"]))
        groups[key]["samples"].append(int(row["sample"]))

expected = {
    (pair, boundary, side, workload)
    for pair in (1, 2, 3)
    for boundary in ("raw", "public")
    for side in ("reference", "finalist")
    for workload in names
}
missing = sorted(expected - set(groups))
unexpected = sorted(set(groups) - expected)
if missing:
    raise SystemExit("missing expected groups:\n" + "\n".join(map(str, missing)))
if unexpected:
    raise SystemExit("unexpected groups:\n" + "\n".join(map(str, unexpected)))

rows = []
medians = {}
for key in sorted(groups):
    pair, boundary, side, workload = key
    values = groups[key]
    if sorted(values["samples"]) != list(range(1, 10)):
        raise SystemExit(f"{pair}/{boundary}/{side}/{workload}: expected samples 1..9 exactly once")
    if len(values["operations"]) != 1:
        raise SystemExit(f"{pair}/{boundary}/{side}/{workload}: calibration changed in-process")
    median_wall = statistics.median(values["wall"])
    median_words = statistics.median(values["words"])
    medians[key] = (median_wall, median_words)
    rows.append(
        {
            "pair": pair,
            "boundary": boundary,
            "side": side,
            "workload": workload,
            "operations": next(iter(values["operations"])),
            "median_wall_ns": median_wall,
            "median_allocated_words": median_words,
        }
    )

with target.open("w", newline="") as handle:
    fields = list(rows[0])
    writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)

failed = []
for workload in names:
    public_passes = 0
    raw_wall_passes = 0
    allocation_passes = 0
    limit, inclusive = allocation_limits[workload]
    for pair in (1, 2, 3):
        public_reference = medians[(pair, "public", "reference", workload)][0]
        public_finalist = medians[(pair, "public", "finalist", workload)][0]
        raw_reference = medians[(pair, "raw", "reference", workload)][0]
        raw_finalist, raw_words = medians[(pair, "raw", "finalist", workload)]
        public_ratio = public_finalist / public_reference
        raw_ratio = raw_finalist / raw_reference
        allocation_ok = raw_words <= limit if inclusive else raw_words < limit
        public_passes += public_ratio <= 1.20
        raw_wall_passes += raw_ratio <= 1.20
        allocation_passes += allocation_ok
        relation = "<=" if inclusive else "<"
        print(
            f"{workload} pair={pair}: public_wall={public_ratio:.6f} "
            f"raw_wall={raw_ratio:.6f} raw_words={raw_words:.6f} "
            f"({relation} {limit:g})"
        )
    accepted = public_passes >= 2 and raw_wall_passes >= 2 and allocation_passes == 3
    print(
        f"{workload}: {'ACCEPT' if accepted else 'REJECT'} "
        f"public_wall={public_passes}/3 raw_wall={raw_wall_passes}/3 "
        f"allocation={allocation_passes}/3"
    )
    if not accepted:
        failed.append(workload)

if failed:
    raise SystemExit("performance acceptance failed: " + ", ".join(failed))
