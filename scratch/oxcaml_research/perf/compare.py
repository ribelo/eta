#!/usr/bin/env python3
"""Side-by-side comparison of mainline vs oxcaml bench runs.
Reads scratch/oxcaml_research/perf/{mainline,oxcaml}.json and emits a
tab-separated diff for every wall_ns benchmark plus a summary header."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PERF = ROOT / "scratch/oxcaml_research/perf"

def load(label):
    data = json.loads((PERF / f"{label}.json").read_text())
    by_key = {}
    for b in data["benchmarks"]:
        if b.get("metric") != "wall_ns":
            continue
        by_key[b["name"]] = b["mean"]
    return data, by_key

m_meta, m = load("mainline")
o_meta, o = load("oxcaml")

print(f"# Effet bench: mainline {m_meta['ocaml_version']} vs oxcaml {o_meta['ocaml_version']}")
print(f"# CPU: {m_meta['cpu_model']}")
print(f"# Mainline total: {m_meta['duration_ms']} ms  Oxcaml total: {o_meta['duration_ms']} ms")
print()
print(f"{'benchmark':<60}  {'mainline_ns':>14}  {'oxcaml_ns':>14}  {'ratio':>7}  {'verdict':<10}")
print("-" * 110)

names = sorted(set(m) | set(o))
faster = slower = same = 0
ratios = []
for name in names:
    mv = m.get(name)
    ov = o.get(name)
    if mv is None or ov is None:
        print(f"{name:<60}  {(mv or 0):>14.2f}  {(ov or 0):>14.2f}  {'n/a':>7}  missing")
        continue
    ratio = ov / mv if mv > 0 else float('inf')
    ratios.append(ratio)
    if ratio < 0.95:
        verdict = "faster"; faster += 1
    elif ratio > 1.05:
        verdict = "slower"; slower += 1
    else:
        verdict = "same"; same += 1
    print(f"{name:<60}  {mv:>14.2f}  {ov:>14.2f}  {ratio:>7.3f}  {verdict:<10}")

print()
n = faster + slower + same
print(f"# Summary: {faster}/{n} faster (>5% improvement under oxcaml), "
      f"{slower}/{n} slower (>5% regression), {same}/{n} same.")
if ratios:
    nonzero = [r for r in ratios if r > 0]
    nonzero.sort()
    geomean = 1
    for r in nonzero:
        geomean *= r
    geomean **= (1 / len(nonzero))
    median = nonzero[len(nonzero)//2]
    print(f"# wall_ns ratio (oxcaml/mainline, oxcaml<1 means oxcaml faster):")
    print(f"#   geomean: {geomean:.3f}  median: {median:.3f}  "
          f"min: {nonzero[0]:.3f}  max: {nonzero[-1]:.3f}  (n={len(nonzero)} wall_ns benches)")
