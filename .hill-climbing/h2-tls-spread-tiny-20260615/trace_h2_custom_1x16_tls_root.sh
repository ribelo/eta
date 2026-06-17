#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_CUSTOM_1X16_REQUESTS:-12000}"
CONCURRENCY="${ETA_H2_CUSTOM_1X16_CONCURRENCY:-16}"
REPEATS="${ETA_H2_CUSTOM_1X16_REPEATS:-1}"
PATH_UNDER_TEST="${ETA_H2_CUSTOM_1X16_PATH:-/}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/custom-h2-1x16-tls-root-results/$STAMP"
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
mkdir -p "$RESULT_DIR" "$TMP_DIR/server"

nix develop -c dune build \
  http-testsuite/test/server_load/h2_tls_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

PORT=$((27000 + RANDOM % 12000))
SERVER_LOG="$RESULT_DIR/server.log"
SERVER_H2_TRACE="$RESULT_DIR/server-h2-phase.log"

ETA_H2_PHASE_TRACE_PATH="$SERVER_H2_TRACE" \
  taskset -c "${ETA_SERVER_LOAD_SERVER_CORE:-2}" \
  _build/default/http-testsuite/test/server_load/h2_tls_probe.exe \
  "$PORT" "$TMP_DIR/server" >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

ready=0
for _ in $(seq 1 200); do
  if grep -q "READY $PORT" "$SERVER_LOG"; then
    ready=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  sleep 0.05
done
if [[ "$ready" -ne 1 ]]; then
  cat "$SERVER_LOG" >&2
  exit 1
fi

ETA_H2_GAP_TLS_CA_FILE="$TMP_DIR/server/certs/ca.pem" \
ETA_H2_GAP_METHOD=GET \
ETA_H2_GAP_BODY_BYTES=0 \
  taskset -c "${ETA_SERVER_LOAD_LOAD_CORE:-3}" \
  _build/default/http-testsuite/test/server_load/h2_gap_client.exe \
  127.0.0.1 "$PORT" "$REQUESTS" "$CONCURRENCY" "$REPEATS" \
  "$RESULT_DIR/client.tsv" "$PATH_UNDER_TEST" \
  >"$RESULT_DIR/client.out" 2>"$RESULT_DIR/client.err"

sleep 0.2
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

python3 - "$RESULT_DIR/client.tsv" "$SERVER_H2_TRACE" "$REQUESTS" "$REPEATS" <<'PY'
import csv
import math
import re
import sys
from pathlib import Path

client_path = Path(sys.argv[1])
trace_path = Path(sys.argv[2])
expected_requests = int(sys.argv[3])
repeats = int(sys.argv[4])
expected_samples = expected_requests * repeats

def pct(values, percentile):
    if not values:
        return 0
    ordered = sorted(values)
    index = max(
        0,
        min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1),
    )
    return ordered[index]

def positive_time(row, key):
    value = int(row[key])
    return value if value >= 0 else None

samples = []
errors = 0
with client_path.open() as f:
    reader = csv.DictReader(f, delimiter="\t")
    for row in reader:
        if row["error"]:
            errors += 1
            continue
        if int(row["status"]) != 200:
            errors += 1
            continue
        t0 = positive_time(row, "t0_us")
        t1 = positive_time(row, "t1_us")
        t2 = positive_time(row, "t2_us")
        t3 = positive_time(row, "t3_us")
        rx_headers = positive_time(row, "rx_headers_us")
        rx_body_end = positive_time(row, "rx_body_end_us")
        rx_feed_start = positive_time(row, "rx_feed_start_us")
        rx_feed_end = positive_time(row, "rx_feed_end_us")
        tx_ready = positive_time(row, "tx_ready_us")
        if None in (t0, t1, t2, t3):
            errors += 1
            continue
        samples.append(
            {
                "t0": t0,
                "t1": t1,
                "t2": t2,
                "t3": t3,
                "tx_ready": tx_ready,
                "rx_headers": rx_headers,
                "rx_body_end": rx_body_end,
                "rx_feed_start": rx_feed_start,
                "rx_feed_end": rx_feed_end,
            }
        )

patterns = {
    "write_complete_response": re.compile(
        r"h2(?:_phase)?_write_complete .*response_write_us=(\d+)"
    ),
    "write_ready": re.compile(r"h2(?:_phase)?_write_ready .*wait_us=(\d+)"),
    "write_job_wait": re.compile(
        r"h2(?:_phase)?_write_job_start .*job_wait_us=(\d+)"
    ),
    "flow_write": re.compile(
        r"h2(?:_phase)?_write_flow_complete .*flow_write_us=(\d+)"
    ),
}
trace_values = {name: [] for name in patterns}
if trace_path.exists():
    for line in trace_path.read_text().splitlines():
        for name, pattern in patterns.items():
            match = pattern.search(line)
            if match:
                trace_values[name].append(int(match.group(1)))

def values(expr):
    out = []
    for sample in samples:
        value = expr(sample)
        if value is not None and value >= 0:
            out.append(value)
    return out

total = values(lambda s: s["t3"] - s["t0"])
t0_t1 = values(lambda s: s["t1"] - s["t0"])
t1_t2 = values(lambda s: s["t2"] - s["t1"])
t2_t3 = values(lambda s: s["t3"] - s["t2"])
tx_ready_to_written = values(
    lambda s: None if s["tx_ready"] is None else s["t1"] - s["tx_ready"]
)
rx_headers_to_handler = values(
    lambda s: None if s["rx_headers"] is None else s["t2"] - s["rx_headers"]
)
request_written_to_rx_headers = values(
    lambda s: None if s["rx_headers"] is None else s["rx_headers"] - s["t1"]
)
rx_feed = values(
    lambda s: None
    if s["rx_feed_start"] is None or s["rx_feed_end"] is None
    else s["rx_feed_end"] - s["rx_feed_start"]
)

print(f"custom_h2_1x16_result_dir\t{client_path.parent}")
print(f"custom_h2_1x16_samples\t{len(samples)}")
print(f"custom_h2_1x16_errors\t{errors}")
print(f"custom_h2_1x16_expected_samples\t{expected_samples}")
print(
    "custom_h2_1x16_summary\t"
    f"total_p50_us={pct(total, 50)}\t"
    f"total_p95_us={pct(total, 95)}\t"
    f"total_p99_us={pct(total, 99)}\t"
    f"t0_t1_p99_us={pct(t0_t1, 99)}\t"
    f"t1_t2_p99_us={pct(t1_t2, 99)}\t"
    f"t1_rx_headers_p99_us={pct(request_written_to_rx_headers, 99)}\t"
    f"t2_t3_p99_us={pct(t2_t3, 99)}\t"
    f"server_write_complete_p99_us={pct(trace_values['write_complete_response'], 99)}"
)

metrics = {
    "custom_h2_1x16_success": 1
    if errors == 0 and len(samples) == expected_samples
    else 0,
    "custom_h2_1x16_total_p50_us": pct(total, 50),
    "custom_h2_1x16_total_p95_us": pct(total, 95),
    "custom_h2_1x16_total_p99_us": pct(total, 99),
    "custom_h2_1x16_t0_t1_p99_us": pct(t0_t1, 99),
    "custom_h2_1x16_t1_t2_p99_us": pct(t1_t2, 99),
    "custom_h2_1x16_t2_t3_p99_us": pct(t2_t3, 99),
    "custom_h2_1x16_tx_ready_to_written_p99_us": pct(tx_ready_to_written, 99),
    "custom_h2_1x16_t1_rx_headers_p99_us": pct(
        request_written_to_rx_headers, 99
    ),
    "custom_h2_1x16_rx_headers_to_handler_p99_us": pct(rx_headers_to_handler, 99),
    "custom_h2_1x16_rx_feed_p99_us": pct(rx_feed, 99),
    "custom_h2_1x16_server_write_complete_response_p99_us": pct(
        trace_values["write_complete_response"], 99
    ),
    "custom_h2_1x16_server_write_ready_p99_us": pct(trace_values["write_ready"], 99),
    "custom_h2_1x16_server_write_job_wait_p99_us": pct(
        trace_values["write_job_wait"], 99
    ),
    "custom_h2_1x16_server_flow_write_p99_us": pct(trace_values["flow_write"], 99),
}
for name, value in metrics.items():
    print(f"METRIC {name}={float(value):.6f}")
PY
