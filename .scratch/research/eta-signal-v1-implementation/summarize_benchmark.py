#!/usr/bin/env python3

import argparse
import csv
import json
import statistics
from pathlib import Path


PAIRS = [
    (
        "Changed scalar, depth 1",
        "eta_signal.changed.depth_1",
        "incremental.changed.depth_1",
    ),
    (
        "Changed scalar, depth 10",
        "eta_signal.changed.depth_10",
        "incremental.changed.depth_10",
    ),
    (
        "Changed scalar, depth 100",
        "eta_signal.changed.depth_100",
        "incremental.changed.depth_100",
    ),
    (
        "Cutoff before 10 dependents",
        "eta_signal.cutoff.depth_10",
        "incremental.cutoff.depth_10",
    ),
    (
        "Dynamic branch switch",
        "eta_signal.dynamic.switch",
        "incremental.dynamic.switch",
    ),
    (
        "One data change, 10k keys",
        "eta_signal_map.data_change.10000",
        "incr_map.data_change.10000",
    ),
    (
        "One data change, 100k keys",
        "eta_signal_map.data_change.100000",
        "incr_map.data_change.100000",
    ),
    (
        "One child change, 10k keys",
        "eta_signal_map.child_change.10000",
        "incr_map.child_change.10000",
    ),
    (
        "One child change, 100k keys",
        "eta_signal_map.child_change.100000",
        "incr_map.child_change.100000",
    ),
]


def process_run(path):
    samples = {}
    with path.open(newline="") as source:
        for row in csv.DictReader(source):
            samples.setdefault(row["name"], []).append(
                (
                    float(row["wall_ns"]),
                    float(row["allocated_words"]),
                )
            )
    return {
        name: {
            "wall_ns": statistics.mean(value[0] for value in values),
            "allocated_words": statistics.mean(value[1] for value in values),
        }
        for name, values in samples.items()
    }


def aggregate(runs):
    names = set.intersection(*(set(run) for run in runs))
    result = {}
    for name in sorted(names):
        wall = [run[name]["wall_ns"] for run in runs]
        words = [run[name]["allocated_words"] for run in runs]
        result[name] = {
            "process_means_wall_ns": wall,
            "median_wall_ns": statistics.median(wall),
            "min_wall_ns": min(wall),
            "max_wall_ns": max(wall),
            "median_allocated_words": statistics.median(words),
        }
    return result


def format_ns(value):
    if value >= 1_000_000_000:
        return f"{value / 1_000_000_000:.3f} s"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.3f} ms"
    if value >= 1_000:
        return f"{value / 1_000:.3f} us"
    return f"{value:.1f} ns"


def write_markdown(path, result):
    lines = [
        "# Signal benchmark baseline",
        "",
        "The value is the median of three process-run means.",
        "Each process run contains nine samples.",
        "",
        "| Workload | Current Eta | Jane Street | Eta / Jane | 1.20× target |",
        "|---|---:|---:|---:|---:|",
    ]
    for label, eta_name, jane_name in PAIRS:
        eta = result[eta_name]["median_wall_ns"]
        jane = result[jane_name]["median_wall_ns"]
        lines.append(
            f"| {label} | {format_ns(eta)} | {format_ns(jane)} "
            f"| {eta / jane:,.1f}× | {format_ns(1.2 * jane)} |"
        )
    lines.extend(
        [
            "",
            "The final Eta value for each row must be less than its current value.",
            "It must also be no more than the listed `1.20×` target.",
            "",
        ]
    )
    path.write_text("\n".join(lines))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("results", type=Path)
    args = parser.parse_args()
    paths = sorted(args.results.glob("run*.csv"))
    if len(paths) != 3:
        raise SystemExit(f"expected three run CSV files, found {len(paths)}")
    runs = [process_run(path) for path in paths]
    result = aggregate(runs)
    (args.results / "summary.json").write_text(
        json.dumps(result, indent=2, sort_keys=True) + "\n"
    )
    write_markdown(args.results / "SUMMARY.md", result)


if __name__ == "__main__":
    main()
