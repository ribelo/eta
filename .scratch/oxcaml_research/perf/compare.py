#!/usr/bin/env python3
"""Side-by-side comparison of mainline vs oxcaml bench runs across multiple
runs per toolchain. Reads scratch/oxcaml_research/perf/{mainline,oxcaml}.N.json
and uses the per-benchmark min across runs as the representative wall_ns
(min is more robust to noise than mean for microbenchmarks)."""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PERF = ROOT / "scratch/oxcaml_research/perf"

def load_runs(label):
    runs = sorted(PERF.glob(f"{label}.*.json"))
    if not runs:
        print(f"no runs for {label}", file=sys.stderr)
        sys.exit(2)
    by_key = {}
    meta = None
    for path in runs:
        data = json.loads(path.read_text())
        meta = data
        for b in data["benchmarks"]:
            if b.get("metric") != "wall_ns":
                continue
            # Use the bench's own min across its 5 internal samples.
            run_min = b["min"]
            cur = by_key.get(b["name"])
            if cur is None or run_min < cur:
                by_key[b["name"]] = run_min
    return meta, by_key, len(runs)

m_meta, m, m_runs = load_runs("mainline")
o_meta, o, o_runs = load_runs("oxcaml")

print(f"# Effet bench: mainline {m_meta['ocaml_version']} ({m_runs} runs) vs "
      f"oxcaml {o_meta['ocaml_version']} ({o_runs} runs)")
print(f"# CPU: {m_meta['cpu_model']}")
print(f"# Per benchmark: min over runs of bench's own min sample.")
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
    if ratio == float('inf') or mv == 0:
        verdict += "*"
    print(f"{name:<60}  {mv:>14.2f}  {ov:>14.2f}  {ratio:>7.3f}  {verdict:<10}")

print()
n = faster + slower + same
print(f"# Summary: {faster}/{n} faster (>5% improvement), "
      f"{slower}/{n} slower (>5% regression), {same}/{n} same (within 5%).")
nonzero = sorted(r for r in ratios if 0 < r < float('inf'))
if nonzero:
    geomean = 1
    for r in nonzero:
        geomean *= r
    geomean **= (1 / len(nonzero))
    median = nonzero[len(nonzero)//2]
    print(f"# wall_ns ratio (oxcaml/mainline; <1 means oxcaml faster):")
    print(f"#   geomean: {geomean:.3f}  median: {median:.3f}  "
          f"min: {nonzero[0]:.3f}  max: {nonzero[-1]:.3f}  (n={len(nonzero)})")
