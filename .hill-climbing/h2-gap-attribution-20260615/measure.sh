#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_GAP_REQUESTS:-24000}"
CONCURRENCY="${ETA_H2_GAP_CONCURRENCY:-16}"
REPEATS="${ETA_H2_GAP_REPEATS:-9}"
PORT="${ETA_H2_GAP_PORT:-$((18000 + RANDOM % 20000))}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/results/$STAMP"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT"
mkdir -p "$RESULT_DIR"

echo "building h2 probe and checkpoint client" >&2
nix develop -c dune build \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

SERVER_TMP="$TMP_DIR/server"
SERVER_LOG="$RESULT_DIR/server.log"
mkdir -p "$SERVER_TMP"

echo "starting H2C probe on port $PORT" >&2
_build/default/http-testsuite/test/server_load/h2_probe.exe \
  "$PORT" "$SERVER_TMP" >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

ready=0
for _ in $(seq 1 200); do
  if grep -q "READY $PORT" "$SERVER_LOG"; then
    ready=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "server exited before ready" >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  sleep 0.05
done

if [[ "$ready" -ne 1 ]]; then
  echo "server did not become ready" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi

RAW_TSV="$RESULT_DIR/client-checkpoints.tsv"
echo "running custom H2C client: requests=$REQUESTS concurrency=$CONCURRENCY repeats=$REPEATS" >&2
_build/default/http-testsuite/test/server_load/h2_gap_client.exe \
  127.0.0.1 "$PORT" "$REQUESTS" "$CONCURRENCY" "$REPEATS" "$RAW_TSV"

python - "$RAW_TSV" "$REQUESTS" "$REPEATS" "$RESULT_DIR/summary.tsv" <<'PY'
import csv
import math
import statistics
import sys
from collections import defaultdict

raw_path, requests_s, repeats_s, summary_path = sys.argv[1:]
requests = int(requests_s)
repeats = int(repeats_s)

def pct(values, p):
    if not values:
        raise SystemExit("no values for percentile")
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil((p / 100.0) * len(ordered)) - 1))
    return ordered[index]

segments = {
    "t0_t1": defaultdict(list),
    "t1_rx_headers": defaultdict(list),
    "rx_headers_t2": defaultdict(list),
    "t1_t2": defaultdict(list),
    "t2_t3": defaultdict(list),
    "t0_t3": defaultdict(list),
}
rows = 0
bad = []

with open(raw_path, newline="") as f:
    reader = csv.DictReader(f, delimiter="\t")
    for row in reader:
        rows += 1
        repeat = int(row["repeat"])
        status = int(row["status"])
        echoed = int(row["bytes"])
        error = row["error"]
        t0 = int(row["t0_us"])
        t1 = int(row["t1_us"])
        t2 = int(row["t2_us"])
        t3 = int(row["t3_us"])
        rx_headers = int(row["rx_headers_us"])
        rx_body_end = int(row["rx_body_end_us"])
        if status != 200 or echoed != 1024 or error or min(t0, t1, t2, t3, rx_headers, rx_body_end) < 0:
            bad.append(row)
            continue
        if not (t0 <= t1 <= rx_headers <= t2 <= t3 and rx_body_end <= t3):
            bad.append(row)
            continue
        segments["t0_t1"][repeat].append(t1 - t0)
        segments["t1_rx_headers"][repeat].append(rx_headers - t1)
        segments["rx_headers_t2"][repeat].append(t2 - rx_headers)
        segments["t1_t2"][repeat].append(t2 - t1)
        segments["t2_t3"][repeat].append(t3 - t2)
        segments["t0_t3"][repeat].append(t3 - t0)

expected = requests * repeats
if rows != expected:
    raise SystemExit(f"expected {expected} rows, saw {rows}")
if bad:
    raise SystemExit(f"{len(bad)} rows failed validation")

repeat_ids = sorted(segments["t0_t3"].keys())
if repeat_ids != list(range(1, repeats + 1)):
    raise SystemExit(f"unexpected repeat ids: {repeat_ids}")
for repeat in repeat_ids:
    if len(segments["t0_t3"][repeat]) != requests:
        raise SystemExit(f"repeat {repeat} has {len(segments['t0_t3'][repeat])} rows")

per_repeat = []
for repeat in repeat_ids:
    entry = {"repeat": repeat}
    for name, by_repeat in segments.items():
        values = by_repeat[repeat]
        entry[f"{name}_p95_ms"] = pct(values, 95.0) / 1000.0
        entry[f"{name}_p99_ms"] = pct(values, 99.0) / 1000.0
        entry[f"{name}_p995_ms"] = pct(values, 99.5) / 1000.0
        entry[f"{name}_max_ms"] = max(values) / 1000.0
    per_repeat.append(entry)

fields = [
    "repeat",
    "t0_t3_p95_ms",
    "t0_t3_p99_ms",
    "t0_t3_p995_ms",
    "t0_t3_max_ms",
    "t0_t1_p99_ms",
    "t1_rx_headers_p99_ms",
    "rx_headers_t2_p99_ms",
    "t1_t2_p99_ms",
    "t2_t3_p99_ms",
]
with open(summary_path, "w", newline="") as f:
    writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields)
    writer.writeheader()
    for entry in per_repeat:
        writer.writerow({field: entry[field] for field in fields})

print("repeat\tt0_t3_p95_ms\tt0_t3_p99_ms\tt0_t3_p995_ms\tt0_t3_max_ms\tt0_t1_p99_ms\tt1_rx_headers_p99_ms\trx_headers_t2_p99_ms\tt1_t2_p99_ms\tt2_t3_p99_ms")
for entry in per_repeat:
    print(
        f"{entry['repeat']}\t"
        f"{entry['t0_t3_p95_ms']:.3f}\t"
        f"{entry['t0_t3_p99_ms']:.3f}\t"
        f"{entry['t0_t3_p995_ms']:.3f}\t"
        f"{entry['t0_t3_max_ms']:.3f}\t"
        f"{entry['t0_t1_p99_ms']:.3f}\t"
        f"{entry['t1_rx_headers_p99_ms']:.3f}\t"
        f"{entry['rx_headers_t2_p99_ms']:.3f}\t"
        f"{entry['t1_t2_p99_ms']:.3f}\t"
        f"{entry['t2_t3_p99_ms']:.3f}"
    )

def median_metric(metric):
    return statistics.median(entry[metric] for entry in per_repeat)

def max_metric(metric):
    return max(entry[metric] for entry in per_repeat)

metrics = {
    "custom_h2c_echo_1x16_t0_t3_p99_ms": median_metric("t0_t3_p99_ms"),
    "custom_h2c_echo_1x16_t0_t3_p995_ms": median_metric("t0_t3_p995_ms"),
    "custom_h2c_echo_1x16_t0_t3_repeat_max_ms": max_metric("t0_t3_max_ms"),
    "custom_h2c_echo_1x16_t0_t1_p99_ms": median_metric("t0_t1_p99_ms"),
    "custom_h2c_echo_1x16_t1_rx_headers_p99_ms": median_metric("t1_rx_headers_p99_ms"),
    "custom_h2c_echo_1x16_rx_headers_t2_p99_ms": median_metric("rx_headers_t2_p99_ms"),
    "custom_h2c_echo_1x16_t1_t2_p99_ms": median_metric("t1_t2_p99_ms"),
    "custom_h2c_echo_1x16_t2_t3_p99_ms": median_metric("t2_t3_p99_ms"),
    "custom_h2c_echo_1x16_success": 1.0,
}
for name, value in metrics.items():
    print(f"METRIC {name}={value:.6f}")
PY

echo "raw checkpoints: $RAW_TSV" >&2
echo "summary: $RESULT_DIR/summary.tsv" >&2
