#!/usr/bin/env python3
"""Validate and summarize the exact production/candidate edge matrix."""

import csv
import statistics
import sys
from collections import defaultdict
from pathlib import Path

WORKLOADS = (
    "failed_retry.depth_1.position_last",
    "failed_retry.depth_10.position_last",
    "failed_retry.depth_100.position_last",
    "dynamic_scope_cleanup",
    "cancelled_contender",
    "observer_failure_retry",
    "observer_disposal",
    "timer_cycle",
)
SIDES = ("reference", "candidate")
PAIRS = (1, 2, 3)
SAMPLES = list(range(1, 10))


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: summarize_edges.py RAW.csv SUMMARY.csv")
    source, target = map(Path, sys.argv[1:])
    groups = defaultdict(
        lambda: {"wall": [], "words": [], "operations": set(), "samples": []}
    )
    with source.open(newline="") as handle:
        for row in csv.DictReader(handle):
            key = (int(row["pair"]), row["side"], row["name"])
            groups[key]["wall"].append(float(row["wall_ns"]))
            groups[key]["words"].append(float(row["allocated_words"]))
            groups[key]["operations"].add(int(row["operations"]))
            groups[key]["samples"].append(int(row["sample"]))

    expected = {
        (pair, side, workload)
        for pair in PAIRS
        for side in SIDES
        for workload in WORKLOADS
    }
    missing = sorted(expected - set(groups))
    unexpected = sorted(set(groups) - expected)
    if missing:
        raise SystemExit("missing expected groups:\n" + "\n".join(map(str, missing)))
    if unexpected:
        raise SystemExit(
            "unexpected groups:\n" + "\n".join(map(str, unexpected))
        )

    medians = {}
    rows = []
    for key in sorted(groups):
        values = groups[key]
        if sorted(values["samples"]) != SAMPLES:
            raise SystemExit(f"{key}: expected samples 1..9 exactly once")
        if len(values["operations"]) != 1:
            raise SystemExit(f"{key}: calibration changed within one process")
        median_wall = statistics.median(values["wall"])
        median_words = statistics.median(values["words"])
        medians[key] = (median_wall, median_words)
        pair, side, workload = key
        rows.append(
            {
                "pair": pair,
                "side": side,
                "name": workload,
                "operations": next(iter(values["operations"])),
                "median_wall_ns": median_wall,
                "median_allocated_words": median_words,
            }
        )

    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("w", newline="") as handle:
        writer = csv.DictWriter(
            handle, fieldnames=rows[0].keys(), lineterminator="\n"
        )
        writer.writeheader()
        writer.writerows(rows)

    failed = []
    for workload in WORKLOADS:
        wall_wins = 0
        allocation_wins = 0
        for pair in PAIRS:
            reference_wall, reference_words = medians[
                (pair, "reference", workload)
            ]
            candidate_wall, candidate_words = medians[
                (pair, "candidate", workload)
            ]
            wall_ok = candidate_wall <= reference_wall
            allocation_ok = candidate_words <= reference_words
            wall_wins += wall_ok
            allocation_wins += allocation_ok
            print(
                f"{workload} pair={pair}: "
                f"wall={candidate_wall:.6f}/{reference_wall:.6f} "
                f"allocation={candidate_words:.6f}/{reference_words:.6f}"
            )
        accepted = wall_wins >= 2 and allocation_wins == 3
        print(
            f"{workload}: {'ACCEPT' if accepted else 'REJECT'} "
            f"wall={wall_wins}/3 allocation={allocation_wins}/3"
        )
        if not accepted:
            failed.append(workload)
    if failed:
        raise SystemExit("edge acceptance failed: " + ", ".join(failed))


if __name__ == "__main__":
    main()
