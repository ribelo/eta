#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_CUSTOM_SPREAD_REQUESTS:-12000}"
CONNECTIONS="${ETA_H2_CUSTOM_SPREAD_CONNECTIONS:-16}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/custom-h2-spread-results/$STAMP"
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

if (( REQUESTS % CONNECTIONS != 0 )); then
  echo "REQUESTS must be divisible by CONNECTIONS for this fixed-shape probe" >&2
  exit 2
fi
PER_CONNECTION=$((REQUESTS / CONNECTIONS))

nix develop -c dune build \
  http-testsuite/test/server_load/h2_tls_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

PORT=$((26000 + RANDOM % 12000))
SERVER_LOG="$RESULT_DIR/server.log"
SERVER_H2_TRACE="$RESULT_DIR/server-h2.log"

ETA_H2_ECHO_TRACE_PATH="$SERVER_H2_TRACE" \
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

CLIENT_PIDS=()
for connection in $(seq 0 $((CONNECTIONS - 1))); do
  ETA_H2_GAP_TLS_CA_FILE="$TMP_DIR/server/certs/ca.pem" \
  ETA_H2_GAP_METHOD=GET \
  ETA_H2_GAP_BODY_BYTES=0 \
    taskset -c "${ETA_SERVER_LOAD_LOAD_CORE:-3}" \
    _build/default/http-testsuite/test/server_load/h2_gap_client.exe \
    127.0.0.1 "$PORT" "$PER_CONNECTION" 1 1 \
    "$RESULT_DIR/client-$connection.tsv" / \
    >"$RESULT_DIR/client-$connection.out" \
    2>"$RESULT_DIR/client-$connection.err" &
  CLIENT_PIDS+=("$!")
done

for pid in "${CLIENT_PIDS[@]}"; do
  wait "$pid"
done

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

python3 - "$RESULT_DIR" "$SERVER_H2_TRACE" "$REQUESTS" <<'PY'
import csv
import math
import re
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
trace_path = Path(sys.argv[2])
expected_requests = int(sys.argv[3])

samples = []
errors = 0
for path in sorted(result_dir.glob("client-*.tsv")):
    with path.open() as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            if row["error"]:
                errors += 1
                continue
            status = int(row["status"])
            if status != 200:
                errors += 1
                continue
            t0 = int(row["t0_us"])
            t1 = int(row["t1_us"])
            t2 = int(row["t2_us"])
            t3 = int(row["t3_us"])
            samples.append((t0, t1, t2, t3))

patterns = {
    "write_complete_response": re.compile(r"h2_write_complete .*response_write_us=(\d+)"),
    "flow_write": re.compile(r"h2_write_flow_complete .*flow_write_us=(\d+)"),
    "write_job_wait": re.compile(r"h2_write_job_start .*job_wait_us=(\d+)"),
    "ingress_wait": re.compile(r"h2_ingress_plain_read .*wait_us=(\d+)"),
    "ingress_owner_ack": re.compile(r"h2_ingress_owner_done .*read_to_ack_us=(\d+)"),
}
trace_values = {name: [] for name in patterns}
if trace_path.exists():
    for line in trace_path.read_text().splitlines():
        for name, pattern in patterns.items():
            match = pattern.search(line)
            if match:
                trace_values[name].append(int(match.group(1)))

def pct(values, percentile):
    if not values:
        return 0
    ordered = sorted(values)
    index = max(
        0,
        min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1),
    )
    return ordered[index]

totals = [t3 - t0 for t0, _t1, _t2, t3 in samples]
t0_t1 = [t1 - t0 for t0, t1, _t2, _t3 in samples]
t1_t2 = [t2 - t1 for _t0, t1, t2, _t3 in samples]
t2_t3 = [t3 - t2 for _t0, _t1, t2, t3 in samples]

print(f"custom_h2_result_dir\t{result_dir}")
print(f"custom_h2_samples\t{len(samples)}")
print(f"custom_h2_errors\t{errors}")
print(f"custom_h2_expected_requests\t{expected_requests}")
print(
    "custom_h2_summary\t"
    f"total_p50_us={pct(totals, 50)}\t"
    f"total_p95_us={pct(totals, 95)}\t"
    f"total_p99_us={pct(totals, 99)}\t"
    f"t1_t2_p99_us={pct(t1_t2, 99)}\t"
    f"t2_t3_p99_us={pct(t2_t3, 99)}\t"
    f"flow_write_p99_us={pct(trace_values['flow_write'], 99)}"
)

success = 1 if errors == 0 and len(samples) == expected_requests else 0
metrics = {
    "custom_h2_success": success,
    "custom_h2_total_p50_us": pct(totals, 50),
    "custom_h2_total_p95_us": pct(totals, 95),
    "custom_h2_total_p99_us": pct(totals, 99),
    "custom_h2_t0_t1_p99_us": pct(t0_t1, 99),
    "custom_h2_t1_t2_p99_us": pct(t1_t2, 99),
    "custom_h2_t2_t3_p99_us": pct(t2_t3, 99),
    "custom_h2_write_complete_response_p99_us": pct(trace_values["write_complete_response"], 99),
    "custom_h2_flow_write_p99_us": pct(trace_values["flow_write"], 99),
    "custom_h2_write_job_wait_p99_us": pct(trace_values["write_job_wait"], 99),
    "custom_h2_ingress_wait_p99_us": pct(trace_values["ingress_wait"], 99),
    "custom_h2_ingress_owner_ack_p99_us": pct(trace_values["ingress_owner_ack"], 99),
}
for name, value in metrics.items():
    print(f"METRIC {name}={float(value):.6f}")
PY
