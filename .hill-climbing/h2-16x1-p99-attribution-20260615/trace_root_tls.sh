#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_16X1_TRACE_REQUESTS:-24000}"
TIMEOUT="${ETA_H2_16X1_TRACE_TIMEOUT:-10s}"
CONNECTIONS="${ETA_H2_16X1_CONNECTIONS:-16}"
STREAMS="${ETA_H2_16X1_STREAMS:-1}"
MODE="${ETA_H2_16X1_TRACE_MODE:-tls}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/trace-results/$STAMP"
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

if [[ "$MODE" != "tls" && "$MODE" != "plain" ]]; then
  echo "ETA_H2_16X1_TRACE_MODE must be tls or plain" >&2
  exit 2
fi

nix develop -c dune build \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_tls_probe.exe

PORT=$((24000 + RANDOM % 12000))
SERVER_LOG="$RESULT_DIR/server.log"
SERVER_H2_TRACE="$RESULT_DIR/server-h2.log"

PROBE="_build/default/http-testsuite/test/server_load/h2_tls_probe.exe"
SCHEME="https"
TLS_FLAGS=(--insecure)
if [[ "$MODE" == "plain" ]]; then
  PROBE="_build/default/http-testsuite/test/server_load/h2_probe.exe"
  SCHEME="http"
  TLS_FLAGS=()
fi

ETA_H2_PHASE_TRACE_PATH="$SERVER_H2_TRACE" \
  taskset -c "${ETA_SERVER_LOAD_SERVER_CORE:-2}" \
  "$PROBE" \
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

env NO_COLOR=false \
  taskset -c "${ETA_SERVER_LOAD_LOAD_CORE:-3}" \
  oha \
  --no-tui \
  --output-format json \
  --redirect 0 \
  --disable-compression \
  --connect-timeout 2s \
  -t "$TIMEOUT" \
  -c "$CONNECTIONS" \
  -p "$STREAMS" \
  -n "$REQUESTS" \
  --http-version 2 \
  "${TLS_FLAGS[@]}" \
  "$SCHEME://127.0.0.1:$PORT/" \
  >"$RESULT_DIR/oha-root.json" 2>"$RESULT_DIR/oha-root.err"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

python - "$RESULT_DIR/oha-root.json" "$SERVER_H2_TRACE" <<'PY'
import json
import math
import re
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
trace_path = Path(sys.argv[2])
raw = json.loads(json_path.read_text())
lat = raw.get("latencyPercentiles", {})
summary = raw.get("summary", {})

print(f"trace_dir\t{trace_path.parent}")
print(f"oha_p50_us\t{lat.get('p50', 0) * 1_000_000:.0f}")
print(f"oha_p95_us\t{lat.get('p95', 0) * 1_000_000:.0f}")
print(f"oha_p99_us\t{lat.get('p99', 0) * 1_000_000:.0f}")
print(f"oha_p999_us\t{lat.get('p99.9', 0) * 1_000_000:.0f}")
print(f"oha_max_us\t{summary.get('slowest', 0) * 1_000_000:.0f}")

patterns = {
    "write_complete_response_us": re.compile(
        r"h2(?:_phase)?_write_complete .*response_write_us=(\d+)"
    ),
    "write_ready_wait_us": re.compile(
        r"h2(?:_phase)?_write_ready .*wait_us=(\d+)"
    ),
    "write_job_wait_us": re.compile(
        r"h2(?:_phase)?_write_job_start .*job_wait_us=(\d+)"
    ),
    "flow_write_us": re.compile(
        r"h2(?:_phase)?_write_flow_complete .*flow_write_us=(\d+)"
    ),
    "ingress_plain_wait_us": re.compile(
        r"h2(?:_phase)?_ingress_(?:plain_)?read .*wait_us=(\d+)"
    ),
    "ingress_owner_ack_us": re.compile(
        r"h2_ingress_owner_done .*read_to_ack_us=(\d+)"
    ),
}
values = {name: [] for name in patterns}
phase = {}

def phase_row(stream_id):
    return phase.setdefault(stream_id, {})

for line in trace_path.read_text().splitlines():
    match = re.search(
        r"h2(?:_phase)?_response_start .*stream_id=(\d+) .*started_us=(\d+)",
        line,
    )
    if match:
        phase_row(int(match.group(1)))["response_start_us"] = int(match.group(2))

    match = re.search(
        r"h2(?:_phase)?_write_ready .*stream_id=(\d+) .*ready_us=(\d+)",
        line,
    )
    if match:
        phase_row(int(match.group(1)))["write_ready_us"] = int(match.group(2))

    match = re.search(
        r"h2(?:_phase)?_write_job_start .*stream_id=(\d+) .*started_us=(\d+)",
        line,
    )
    if match:
        phase_row(int(match.group(1)))["write_job_start_us"] = int(match.group(2))

    match = re.search(
        r"h2(?:_phase)?_write_flow_complete .*stream_id=(\d+) .*completed_us=(\d+)",
        line,
    )
    if match:
        phase_row(int(match.group(1)))["flow_complete_us"] = int(match.group(2))

    match = re.search(
        r"h2(?:_phase)?_write_complete .*stream_id=(\d+) .*completed_us=(\d+)",
        line,
    )
    if match:
        phase_row(int(match.group(1)))["owner_complete_us"] = int(match.group(2))

    for name, pattern in patterns.items():
        match = pattern.search(line)
        if match:
            values[name].append(int(match.group(1)))

def pct(values, percentile):
    if not values:
        return 0
    ordered = sorted(values)
    index = max(
        0,
        min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1),
    )
    return ordered[index]

print("metric\tn\tp50_us\tp95_us\tp99_us\tp999_us\tmax_us")
for name, samples in values.items():
    max_value = max(samples) if samples else 0
    print(
        f"{name}\t{len(samples)}\t{pct(samples, 50)}\t{pct(samples, 95)}\t"
        f"{pct(samples, 99)}\t{pct(samples, 99.9)}\t{max_value}"
    )

phase_specs = {
    "response_to_write_ready_us": ("response_start_us", "write_ready_us"),
    "write_ready_to_job_start_us": ("write_ready_us", "write_job_start_us"),
    "write_job_start_to_flow_complete_us": (
        "write_job_start_us",
        "flow_complete_us",
    ),
    "flow_complete_to_owner_complete_us": (
        "flow_complete_us",
        "owner_complete_us",
    ),
    "response_to_owner_complete_joined_us": (
        "response_start_us",
        "owner_complete_us",
    ),
}
for name, (start_key, end_key) in phase_specs.items():
    samples = []
    for row in phase.values():
        start = row.get(start_key)
        end = row.get(end_key)
        if start is not None and end is not None and end >= start:
            samples.append(end - start)
    max_value = max(samples) if samples else 0
    print(
        f"{name}\t{len(samples)}\t{pct(samples, 50)}\t{pct(samples, 95)}\t"
        f"{pct(samples, 99)}\t{pct(samples, 99.9)}\t{max_value}"
    )
PY
