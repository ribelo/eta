#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_16X1_PINNING_REQUESTS:-24000}"
MODE="${ETA_H2_16X1_TRACE_MODE:-tls}"
LOAD_CORE_RANGE="${ETA_H2_16X1_LOAD_CORE_RANGE:-3-6}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/pinning-results/$STAMP"

cd "$ROOT"
mkdir -p "$RESULT_DIR"

run_case() {
  local name="$1"
  shift
  local out="$RESULT_DIR/$name.tsv"
  local err="$RESULT_DIR/$name.err"
  echo "pinning case $name: requests=$REQUESTS mode=$MODE env=$*" >&2
  env \
    ETA_H2_16X1_CUSTOM_REQUESTS="$REQUESTS" \
    ETA_H2_16X1_TRACE_MODE="$MODE" \
    "$@" \
    bash "$SESSION_DIR/trace_root_custom_client_16x1.sh" \
    >"$out" 2>"$err"
}

run_case default
run_case load_range ETA_SERVER_LOAD_LOAD_CORE="$LOAD_CORE_RANGE"
run_case posix EIO_BACKEND=posix
run_case posix_load_range EIO_BACKEND=posix ETA_SERVER_LOAD_LOAD_CORE="$LOAD_CORE_RANGE"

python - "$RESULT_DIR" <<'PY'
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
cases = ["default", "load_range", "posix", "posix_load_range"]

def load_case(name):
    values = {}
    path = result_dir / f"{name}.tsv"
    with path.open() as f:
        for line in f:
            line = line.rstrip("\n")
            if "\t" not in line:
                continue
            key, value = line.split("\t", 1)
            values[key] = value
    return values

def f(values, key):
    try:
        return float(values.get(key, "0"))
    except ValueError:
        return 0.0

loaded = {case: load_case(case) for case in cases}

print(f"pinning_result_dir\t{result_dir}")
print(
    "case\tsuccess\ttotal_p99_us\tt1_t2_p99_us\t"
    "t1_to_ingress_p99_us\tresponse_to_flow_p99_us\t"
    "flow_to_rx_p99_us\tslow_write_count\tslow_write_fraction\ttrace_dir"
)
for case in cases:
    values = loaded[case]
    print(
        f"{case}\t"
        f"{int(f(values, 'success'))}\t"
        f"{f(values, 'total_us_p99_us'):.0f}\t"
        f"{f(values, 't1_t2_us_p99_us'):.0f}\t"
        f"{f(values, 't1_to_ingress_returned_us_p99_us'):.0f}\t"
        f"{f(values, 'response_start_to_flow_complete_us_p99_us'):.0f}\t"
        f"{f(values, 'flow_complete_to_rx_headers_us_p99_us'):.0f}\t"
        f"{f(values, 'slow_write_count'):.0f}\t"
        f"{f(values, 'slow_write_fraction'):.6f}\t"
        f"{values.get('trace_dir', '')}"
    )

default_total = f(loaded["default"], "total_us_p99_us")
best_total = min(f(loaded[case], "total_us_p99_us") for case in cases)
default_flow_rx = f(loaded["default"], "flow_complete_to_rx_headers_us_p99_us")
load_flow_rx = f(loaded["load_range"], "flow_complete_to_rx_headers_us_p99_us")

print(f"METRIC h2_16x1_pinning_default_total_p99_us={default_total:.6f}")
print(f"METRIC h2_16x1_pinning_best_total_p99_us={best_total:.6f}")
print(
    "METRIC h2_16x1_pinning_default_to_best_total_ratio="
    f"{(default_total / best_total) if best_total > 0 else 0.0:.6f}"
)
print(f"METRIC h2_16x1_pinning_default_flow_rx_p99_us={default_flow_rx:.6f}")
print(f"METRIC h2_16x1_pinning_load_range_flow_rx_p99_us={load_flow_rx:.6f}")
print(
    "METRIC h2_16x1_pinning_flow_rx_reduction_ratio="
    f"{(default_flow_rx / load_flow_rx) if load_flow_rx > 0 else 0.0:.6f}"
)
PY
