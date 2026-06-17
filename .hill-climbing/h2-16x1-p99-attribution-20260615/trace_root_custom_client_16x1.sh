#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
TOTAL_REQUESTS="${ETA_H2_16X1_CUSTOM_REQUESTS:-24000}"
CONNECTIONS="${ETA_H2_16X1_CONNECTIONS:-16}"
MODE="${ETA_H2_16X1_TRACE_MODE:-tls}"
TIMEOUT="${ETA_H2_GAP_TIMEOUT:-30}"
THRESHOLD_US="${ETA_H2_SLOW_WRITE_TRACE_THRESHOLD_US:-500}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/custom-client-results/$STAMP"
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

if (( TOTAL_REQUESTS % CONNECTIONS != 0 )); then
  echo "TOTAL_REQUESTS must be divisible by CONNECTIONS" >&2
  exit 2
fi
REQUESTS_PER_CONNECTION=$((TOTAL_REQUESTS / CONNECTIONS))

nix develop -c dune build \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_tls_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

PORT=$((24000 + RANDOM % 12000))
SERVER_LOG="$RESULT_DIR/server.log"
SLOW_TRACE="$RESULT_DIR/slow-write.log"
PHASE_TRACE="$RESULT_DIR/phase.log"
PROBE="_build/default/http-testsuite/test/server_load/h2_tls_probe.exe"
CLIENT_TLS_ENV=()
if [[ "$MODE" == "plain" ]]; then
  PROBE="_build/default/http-testsuite/test/server_load/h2_probe.exe"
else
  CLIENT_TLS_ENV=(ETA_H2_GAP_TLS_CA_FILE="$TMP_DIR/server/certs/ca.pem")
fi

ETA_H2_SLOW_WRITE_TRACE_PATH="$SLOW_TRACE" \
ETA_H2_SLOW_WRITE_TRACE_THRESHOLD_US="$THRESHOLD_US" \
ETA_H2_PHASE_TRACE_PATH="$PHASE_TRACE" \
  taskset -c "${ETA_SERVER_LOAD_SERVER_CORE:-2}" \
  "$PROBE" "$PORT" "$TMP_DIR/server" >"$SERVER_LOG" 2>&1 &
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

pids=()
for conn in $(seq 1 "$CONNECTIONS"); do
  out="$RESULT_DIR/client-$conn.tsv"
  err="$RESULT_DIR/client-$conn.err"
  env \
    ETA_H2_GAP_METHOD=GET \
    ETA_H2_GAP_BODY_BYTES=0 \
    ETA_H2_GAP_TIMEOUT="$TIMEOUT" \
    "${CLIENT_TLS_ENV[@]}" \
    taskset -c "${ETA_SERVER_LOAD_LOAD_CORE:-3}" \
    _build/default/http-testsuite/test/server_load/h2_gap_client.exe \
    127.0.0.1 "$PORT" "$REQUESTS_PER_CONNECTION" 1 1 "$out" / \
    >"$err" 2>&1 &
  pids+=("$!")
done

failed=0
for pid in "${pids[@]}"; do
  if ! wait "$pid"; then
    failed=1
  fi
done

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

if [[ "$failed" -ne 0 ]]; then
  echo "one or more custom clients failed" >&2
  exit 1
fi

python - "$RESULT_DIR" "$TOTAL_REQUESTS" "$THRESHOLD_US" "$SLOW_TRACE" "$PHASE_TRACE" <<'PY'
import csv
import math
import re
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
expected = int(sys.argv[2])
threshold_us = int(sys.argv[3])
slow_trace_path = Path(sys.argv[4])
phase_trace_path = Path(sys.argv[5])

rows = []
for path in sorted(result_dir.glob("client-*.tsv")):
    with path.open() as f:
        reader = csv.DictReader(f, delimiter="\t")
        rows.extend(dict(row, client_file=path.name) for row in reader)

def i(row, name):
    return int(row[name])

valid = []
bad = 0
for row in rows:
    if row["error"] or i(row, "status") != 200 or i(row, "bytes") != 0:
        bad += 1
        continue
    t0 = i(row, "t0_us")
    t1 = i(row, "t1_us")
    t2 = i(row, "t2_us")
    t3 = i(row, "t3_us")
    rx_headers = i(row, "rx_headers_us")
    rx_body_end = i(row, "rx_body_end_us")
    rx_feed_start = i(row, "rx_feed_start_us")
    rx_feed_end = i(row, "rx_feed_end_us")
    tx_ready = i(row, "tx_ready_us")
    if min(t0, t1, t2, t3, rx_headers, rx_body_end, rx_feed_start, rx_feed_end, tx_ready) < 0:
        bad += 1
        continue
    valid.append(
        {
            "local_port": i(row, "local_port"),
            "stream_id": i(row, "stream_id"),
            "t1_us": t1,
            "rx_headers_us": rx_headers,
            "total_us": t3 - t0,
            "t0_t1_us": t1 - t0,
            "t1_t2_us": t2 - t1,
            "t2_t3_us": t3 - t2,
            "tx_ready_to_t1_us": t1 - tx_ready,
            "rx_headers_to_t2_us": t2 - rx_headers,
            "rx_feed_us": rx_feed_end - rx_feed_start,
        }
    )

def pct(values, percentile):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1))
    return ordered[index]

def emit_metric(name, values):
    print(f"{name}_p50_us\t{pct(values, 50):.0f}")
    print(f"{name}_p95_us\t{pct(values, 95):.0f}")
    print(f"{name}_p99_us\t{pct(values, 99):.0f}")
    print(f"{name}_p999_us\t{pct(values, 99.9):.0f}")
    print(f"{name}_max_us\t{max(values) if values else 0:.0f}")

print(f"trace_dir\t{result_dir}")
print(f"threshold_us\t{threshold_us}")
print(f"rows\t{len(rows)}")
print(f"valid\t{len(valid)}")
print(f"bad\t{bad}")
print(f"success\t{1 if len(valid) == expected and bad == 0 else 0}")
for key in [
    "total_us",
    "t0_t1_us",
    "t1_t2_us",
    "t2_t3_us",
    "tx_ready_to_t1_us",
    "rx_headers_to_t2_us",
    "rx_feed_us",
]:
    emit_metric(key, [row[key] for row in valid])

slow_durations = []
slow_bytes = []
if slow_trace_path.exists():
    pattern = re.compile(r"bytes=(\d+) duration_us=(\d+)")
    for line in slow_trace_path.read_text().splitlines():
        match = pattern.search(line)
        if match:
            slow_bytes.append(int(match.group(1)))
            slow_durations.append(int(match.group(2)))

print(f"slow_write_count\t{len(slow_durations)}")
print(f"slow_write_fraction\t{len(slow_durations) / expected if expected else 0:.6f}")
print(f"slow_write_p50_us\t{pct(slow_durations, 50):.0f}")
print(f"slow_write_p95_us\t{pct(slow_durations, 95):.0f}")
print(f"slow_write_p99_us\t{pct(slow_durations, 99):.0f}")
print(f"slow_write_max_us\t{max(slow_durations) if slow_durations else 0:.0f}")
print(f"slow_write_median_bytes\t{pct(slow_bytes, 50):.0f}")

def parse_kv_line(line):
    parts = line.split()
    if not parts:
        return None, {}
    fields = {}
    for part in parts[1:]:
        if "=" in part:
            key, value = part.split("=", 1)
            fields[key] = value
    return parts[0], fields

phase = {}
phase_lines = 0
if phase_trace_path.exists():
    for line in phase_trace_path.read_text().splitlines():
        event, fields = parse_kv_line(line)
        if event is None:
            continue
        phase_lines += 1
        try:
            peer_port = int(fields.get("peer_port", "-1"))
            stream_id = int(fields.get("stream_id", "-1"))
        except ValueError:
            continue
        if peer_port < 0 or stream_id <= 0:
            continue
        entry = phase.setdefault((peer_port, stream_id), {})
        if event == "h2_phase_ingress_read":
            entry.setdefault("ingress_started_us", int(fields["started_us"]))
            entry.setdefault("ingress_returned_us", int(fields["returned_us"]))
        elif event == "h2_phase_request_accepted":
            entry.setdefault("accepted_us", int(fields["accepted_us"]))
        elif event == "h2_phase_response_start":
            entry.setdefault("response_start_us", int(fields["started_us"]))
        elif event == "h2_phase_write_flow_complete":
            entry.setdefault("flow_complete_us", int(fields["completed_us"]))

joined = []
for row in valid:
    entry = phase.get((row["local_port"], row["stream_id"]))
    if not entry:
        continue
    required = [
        "ingress_returned_us",
        "accepted_us",
        "response_start_us",
        "flow_complete_us",
    ]
    if any(name not in entry for name in required):
        continue
    joined.append(
        {
            "t1_to_ingress_returned_us": entry["ingress_returned_us"] - row["t1_us"],
            "ingress_returned_to_accepted_us": entry["accepted_us"]
            - entry["ingress_returned_us"],
            "accepted_to_response_start_us": entry["response_start_us"]
            - entry["accepted_us"],
            "response_start_to_flow_complete_us": entry["flow_complete_us"]
            - entry["response_start_us"],
            "flow_complete_to_rx_headers_us": row["rx_headers_us"]
            - entry["flow_complete_us"],
            "t1_to_accepted_us": entry["accepted_us"] - row["t1_us"],
            "t1_to_response_start_us": entry["response_start_us"] - row["t1_us"],
            "t1_to_flow_complete_us": entry["flow_complete_us"] - row["t1_us"],
        }
    )

print(f"phase_trace_lines\t{phase_lines}")
print(f"phase_keys\t{len(phase)}")
print(f"phase_joined\t{len(joined)}")
print(f"phase_missing\t{len(valid) - len(joined)}")
for key in [
    "t1_to_ingress_returned_us",
    "ingress_returned_to_accepted_us",
    "accepted_to_response_start_us",
    "response_start_to_flow_complete_us",
    "flow_complete_to_rx_headers_us",
    "t1_to_accepted_us",
    "t1_to_response_start_us",
    "t1_to_flow_complete_us",
]:
    emit_metric(key, [row[key] for row in joined])
PY
