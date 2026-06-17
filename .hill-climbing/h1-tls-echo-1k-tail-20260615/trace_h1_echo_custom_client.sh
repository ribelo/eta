#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
TOTAL_REQUESTS="${ETA_H1_ECHO_TRACE_REQUESTS:-24000}"
CONNECTIONS="${ETA_H1_ECHO_TRACE_CONNECTIONS:-16}"
MODE="${ETA_H1_ECHO_TRACE_MODE:-tls}"
REQUEST_METHOD="${ETA_H1_ECHO_TRACE_METHOD:-POST}"
REQUEST_BODY_BYTES="${ETA_H1_ECHO_TRACE_BODY_BYTES:-1024}"
REQUEST_PATH="${ETA_H1_ECHO_TRACE_PATH:-/echo}"
EXPECTED_RESPONSE_BYTES="${ETA_H1_ECHO_TRACE_EXPECTED_BYTES:-1024}"
TIMEOUT="${ETA_H1_ECHO_TRACE_TIMEOUT:-30}"
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

bool_env() {
  local name="$1"
  local default="$2"
  local value="${!name:-$default}"
  case "${value,,}" in
    0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

cd "$ROOT"
mkdir -p "$RESULT_DIR" "$TMP_DIR/server"

if [[ "$MODE" != "tls" && "$MODE" != "plain" ]]; then
  echo "ETA_H1_ECHO_TRACE_MODE must be tls or plain" >&2
  exit 2
fi

if (( TOTAL_REQUESTS % CONNECTIONS != 0 )); then
  echo "ETA_H1_ECHO_TRACE_REQUESTS must be divisible by connections" >&2
  exit 2
fi

REQUESTS_PER_CONNECTION=$((TOTAL_REQUESTS / CONNECTIONS))
SERVER_CORE="${ETA_SERVER_LOAD_SERVER_CORE:-2}"
LOAD_CORE="${ETA_SERVER_LOAD_LOAD_CORE:-3}"

nix develop -c dune build \
  http-testsuite/test/server_load/h1_probe.exe \
  http-testsuite/test/server_load/h1_tls_probe.exe

PORT=$((24000 + RANDOM % 12000))
SERVER_LOG="$RESULT_DIR/server.log"
PHASE_TRACE="$RESULT_DIR/phase.log"
EVENT_TRACE="$RESULT_DIR/event.log"
TLS_TRACE="$RESULT_DIR/tls-io.log"
PROBE="_build/default/http-testsuite/test/server_load/h1_probe.exe"
CLIENT_TLS_ENV=()

if [[ "$MODE" == "tls" ]]; then
  PROBE="_build/default/http-testsuite/test/server_load/h1_tls_probe.exe"
  CLIENT_TLS_ENV=(ETA_H1_GAP_TLS_CA_FILE="$TMP_DIR/server/certs/ca.pem")
fi

server_cmd=("$PROBE")
if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
  server_cmd=(taskset -c "$SERVER_CORE" "${server_cmd[@]}")
fi

server_env=(
  ETA_H1_PHASE_TRACE_PATH="$PHASE_TRACE"
  ETA_HTTP_ECHO_TRACE_PATH="$EVENT_TRACE"
  ETA_TLS_IO_TRACE_PATH="$TLS_TRACE"
)

env "${server_env[@]}" "${server_cmd[@]}" "$PORT" "$TMP_DIR/server" \
  >"$SERVER_LOG" 2>&1 &
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
  client_cmd=(
    "$SESSION_DIR/h1_gap_client.py"
    127.0.0.1 "$PORT" "$REQUESTS_PER_CONNECTION" "$out" "$REQUEST_PATH"
  )
  if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
    client_cmd=(taskset -c "$LOAD_CORE" "${client_cmd[@]}")
  fi
  env \
    ETA_H1_GAP_METHOD="$REQUEST_METHOD" \
    ETA_H1_GAP_BODY_BYTES="$REQUEST_BODY_BYTES" \
    ETA_H1_GAP_EXPECTED_RESPONSE_BYTES="$EXPECTED_RESPONSE_BYTES" \
    ETA_H1_GAP_TIMEOUT="$TIMEOUT" \
    "${CLIENT_TLS_ENV[@]}" \
    "${client_cmd[@]}" >"$err" 2>&1 &
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

python - "$RESULT_DIR" "$TOTAL_REQUESTS" "$PHASE_TRACE" "$EVENT_TRACE" "$TLS_TRACE" "$REQUEST_METHOD" "$REQUEST_PATH" "$REQUEST_BODY_BYTES" "$EXPECTED_RESPONSE_BYTES" <<'PY'
import csv
import math
import re
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
expected = int(sys.argv[2])
phase_trace_path = Path(sys.argv[3])
event_trace_path = Path(sys.argv[4])
tls_trace_path = Path(sys.argv[5])
request_method = sys.argv[6]
request_path = sys.argv[7]
request_body_bytes = int(sys.argv[8])
expected_response_bytes = int(sys.argv[9])

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
    if row["error"] or i(row, "status") != 200 or i(row, "bytes") != expected_response_bytes:
        bad += 1
        continue
    t0 = i(row, "t0_us")
    t1 = i(row, "t1_us")
    t2 = i(row, "t2_us")
    t3 = i(row, "t3_us")
    if min(t0, t1, t2, t3) < 0:
        bad += 1
        continue
    valid.append(
        {
            "client_file": row["client_file"],
            "ordinal": i(row, "index"),
            "local_port": i(row, "local_port"),
            "t1_us": t1,
            "rx_headers_us": t2,
            "total_us": t3 - t0,
            "t0_t1_us": t1 - t0,
            "t1_t2_us": t2 - t1,
            "t2_t3_us": t3 - t2,
        }
    )

def pct(values, percentile):
    values = list(values)
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1))
    return float(ordered[index])

metrics = {}

def record_dist(name, values):
    values = list(values)
    metrics[f"{name}_p50_us"] = pct(values, 50)
    metrics[f"{name}_p95_us"] = pct(values, 95)
    metrics[f"{name}_p99_us"] = pct(values, 99)
    metrics[f"{name}_p999_us"] = pct(values, 99.9)
    metrics[f"{name}_max_us"] = float(max(values) if values else 0)

for key in ["total_us", "t0_t1_us", "t1_t2_us", "t2_t3_us"]:
    record_dist(key, [row[key] for row in valid])

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
connection_ordinals = {}
if phase_trace_path.exists():
    for line in phase_trace_path.read_text().splitlines():
        event, fields = parse_kv_line(line)
        if event is None:
            continue
        phase_lines += 1
        try:
            peer_port = int(fields.get("peer_port", "-1"))
            ordinal = int(fields.get("ordinal", "-1"))
        except ValueError:
            continue
        if peer_port < 0 or ordinal <= 0:
            continue
        connection_id = fields.get("connection_id", "")
        if connection_id:
            connection_ordinals[(connection_id, ordinal)] = (peer_port, ordinal)
        entry = phase.setdefault((peer_port, ordinal), {})
        try:
            if event == "h1_phase_request_head":
                entry["request_head_us"] = int(fields["completed_us"])
                entry["request_head_read_us"] = int(fields["read_us"])
            elif event == "h1_phase_request_accepted":
                entry["accepted_us"] = int(fields["accepted_us"])
            elif event == "h1_phase_handler_start":
                entry["handler_start_us"] = int(fields["started_us"])
            elif event == "h1_phase_handler_done":
                entry["handler_done_us"] = int(fields["completed_us"])
                entry["handler_us"] = int(fields["handler_us"])
            elif event == "h1_phase_response_write_start":
                entry.setdefault("write_start_us", int(fields["started_us"]))
                entry["write_bytes"] = entry.get("write_bytes", 0) + int(fields["bytes"])
            elif event == "h1_phase_response_write_complete":
                entry["write_complete_us"] = int(fields["completed_us"])
                entry["write_us"] = entry.get("write_us", 0) + int(fields["write_us"])
            elif event == "h1_phase_request_complete":
                entry["request_complete_us"] = int(fields["completed_us"])
        except (KeyError, ValueError):
            pass

event_lines = 0
if event_trace_path.exists():
    for line in event_trace_path.read_text().splitlines():
        event, fields = parse_kv_line(line)
        if event != "echo_handler":
            continue
        event_lines += 1
        request_id = fields.get("request_id", "")
        match = re.search(r"/request-(\d+)$", request_id)
        if not match:
            continue
        try:
            ordinal = int(match.group(1))
            connection_id = fields["connection_id"]
            key = connection_ordinals.get((connection_id, ordinal))
            if key is None:
                continue
            entry = phase.setdefault(key, {})
            entry["handler_request_body_read_us"] = int(fields["request_body_read_us"])
            entry["handler_body_bytes"] = int(fields["body_bytes"])
            entry["handler_copy_bytes"] = int(fields["handler_copy_bytes"])
        except (KeyError, ValueError):
            pass

joined = []
required = ["request_head_us", "accepted_us", "handler_start_us", "handler_done_us", "write_start_us", "write_complete_us"]
for row in valid:
    entry = phase.get((row["local_port"], row["ordinal"]))
    if not entry or any(name not in entry for name in required):
        continue
    joined_row = {
        **row,
        "t1_to_request_head_us": entry["request_head_us"] - row["t1_us"],
        "request_head_to_accepted_us": entry["accepted_us"] - entry["request_head_us"],
        "accepted_to_handler_start_us": entry["handler_start_us"] - entry["accepted_us"],
        "handler_us": entry["handler_us"],
        "handler_to_write_start_us": entry["write_start_us"] - entry["handler_done_us"],
        "response_write_us": entry["write_complete_us"] - entry["write_start_us"],
        "flow_complete_to_rx_headers_us": row["rx_headers_us"] - entry["write_complete_us"],
        "t1_to_write_complete_us": entry["write_complete_us"] - row["t1_us"],
    }
    for name in ["handler_request_body_read_us", "handler_body_bytes", "handler_copy_bytes", "write_bytes", "write_us", "request_head_read_us"]:
        if name in entry:
            joined_row[name] = entry[name]
    joined.append(joined_row)

for key in [
    "t1_to_request_head_us",
    "request_head_to_accepted_us",
    "accepted_to_handler_start_us",
    "handler_us",
    "handler_request_body_read_us",
    "handler_body_bytes",
    "handler_copy_bytes",
    "handler_to_write_start_us",
    "response_write_us",
    "write_us",
    "write_bytes",
    "flow_complete_to_rx_headers_us",
    "t1_to_write_complete_us",
    "request_head_read_us",
]:
    record_dist(key, [row[key] for row in joined if key in row])

tls_raw_reads = []
tls_raw_writes = []
if tls_trace_path.exists():
    for line in tls_trace_path.read_text().splitlines():
        event, fields = parse_kv_line(line)
        try:
            if event == "tls_raw_read":
                tls_raw_reads.append(int(fields["wait_us"]))
            elif event == "tls_raw_write":
                tls_raw_writes.append(int(fields["write_us"]))
        except (KeyError, ValueError):
            pass

record_dist("tls_raw_read", tls_raw_reads)
record_dist("tls_raw_write", tls_raw_writes)
metrics["tls_raw_read_count"] = float(len(tls_raw_reads))
metrics["tls_raw_write_count"] = float(len(tls_raw_writes))
metrics["rows"] = float(len(rows))
metrics["valid"] = float(len(valid))
metrics["bad"] = float(bad)
metrics["success"] = 1.0 if len(valid) == expected and bad == 0 else 0.0
metrics["phase_trace_lines"] = float(phase_lines)
metrics["phase_keys"] = float(len(phase))
metrics["phase_joined"] = float(len(joined))
metrics["phase_missing"] = float(len(valid) - len(joined))
metrics["event_trace_lines"] = float(event_lines)

print(f"trace_dir\t{result_dir}")
print(f"request_method\t{request_method}")
print(f"request_path\t{request_path}")
print(f"request_body_bytes\t{request_body_bytes}")
print(f"expected_response_bytes\t{expected_response_bytes}")
for name in sorted(metrics):
    value = metrics[name]
    if value.is_integer():
        print(f"{name}\t{int(value)}")
    else:
        print(f"{name}\t{value:.6f}")

print(
    "top_total_us\tclient_file\tlocal_port\tordinal\tt1_write_complete_us\t"
    "handler_body_read_us\tresponse_write_us\tflow_rx_headers_us\tt2_t3_us"
)
for row in sorted(joined, key=lambda item: item["total_us"], reverse=True)[:20]:
    print(
        f"{row['total_us']}\t{row['client_file']}\t{row['local_port']}\t"
        f"{row['ordinal']}\t{row['t1_to_write_complete_us']}\t"
        f"{row.get('handler_request_body_read_us', -1)}\t"
        f"{row['response_write_us']}\t{row['flow_complete_to_rx_headers_us']}\t"
        f"{row['t2_t3_us']}"
    )

for name in sorted(metrics):
    print(f"METRIC h1_echo_trace_{name}={metrics[name]:.6f}")
PY
