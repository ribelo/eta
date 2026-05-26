#!/usr/bin/env bash
# Autoresearch benchmark for Eta fanout performance only.

set -euo pipefail

cd "$(dirname "$0")"

export EIO_BACKEND="${EIO_BACKEND:-posix}"
SAMPLES="${SAMPLES:-10}"

nix develop -c dune build --profile=release \
  bench/runtime_real/runtime_real.exe \
  bench/runtime_concurrency/runtime_concurrency.exe >/dev/null

real_json="$(_build/default/bench/runtime_real/runtime_real.exe \
  --samples "$SAMPLES" \
  --filter 'realuse.fanout.par.success.64x50|realuse.fanout.bounded.512x50.k=8')"

concurrency_json="$(_build/default/bench/runtime_concurrency/runtime_concurrency.exe \
  --samples "$SAMPLES" \
  --filter 'effect.concurrency.for_each_par.64|effect.concurrency.for_each_par_bounded.512.8')"

python3 - "$real_json" "$concurrency_json" <<'PY'
import json, sys

real_raw, conc_raw = sys.argv[1], sys.argv[2]

def parse(raw):
    rows = []
    for line in raw.splitlines():
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    return {(r["name"], r["metric"]): r for r in rows}

real = parse(real_raw)
conc = parse(conc_raw)

par = real[("realuse.fanout.par.success.64x50", "wall_ns")]
bounded = real[("realuse.fanout.bounded.512x50.k=8", "wall_ns")]

total = par["mean"] + bounded["mean"]
print(f"METRIC fanout_total_ns={total:.0f}")

metric_names = {
    "realuse.fanout.par.success.64x50": "fanout_par_64x50",
    "realuse.fanout.bounded.512x50.k=8": "fanout_bounded_512x50_k8",
}
for bench_name, short in metric_names.items():
    for metric in ["wall_ns", "minor_words", "major_words"]:
        row = real[(bench_name, metric)]
        suffix = "ns" if metric == "wall_ns" else metric
        print(f"METRIC {short}_{suffix}={row['mean']:.0f}")
        if metric == "wall_ns":
            print(f"METRIC {short}_min_ns={row['min']:.0f}")

conc_names = {
    "effect.concurrency.for_each_par.64": "concurrency_for_each_par_64",
    "effect.concurrency.for_each_par_bounded.512.8": "concurrency_for_each_par_bounded_512_8",
}
for bench_name, short in conc_names.items():
    row = conc[(bench_name, "wall_ns")]
    print(f"METRIC {short}_ns={row['mean']:.0f}")
    print(f"METRIC {short}_min_ns={row['min']:.0f}")
PY
