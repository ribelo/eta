#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
TOTAL_REQUESTS="${ETA_H2_ECHO_4X4_TRACE_REQUESTS:-24000}"
CONNECTIONS="${ETA_H2_ECHO_4X4_TRACE_CONNECTIONS:-4}"
STREAMS_PER_CONNECTION="${ETA_H2_ECHO_4X4_TRACE_STREAMS:-4}"
MODE="${ETA_H2_ECHO_4X4_TRACE_MODE:-plain}"
TIMEOUT="${ETA_H2_GAP_TIMEOUT:-30}"
THRESHOLD_US="${ETA_H2_SLOW_WRITE_TRACE_THRESHOLD_US:-500}"
ENABLE_EVENT_TRACE="${ETA_H2_ECHO_4X4_TRACE_EVENTS:-true}"
REQUEST_METHOD="${ETA_H2_ECHO_4X4_TRACE_METHOD:-POST}"
REQUEST_BODY_BYTES="${ETA_H2_ECHO_4X4_TRACE_BODY_BYTES:-1024}"
REQUEST_PATH="${ETA_H2_ECHO_4X4_TRACE_PATH:-/echo}"
EXPECTED_RESPONSE_BYTES="${ETA_H2_ECHO_4X4_TRACE_EXPECTED_BYTES:-1024}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_ROOT="${ETA_H2_ECHO_4X4_TRACE_RESULT_ROOT:-$SESSION_DIR/custom-client-results}"
RESULT_DIR="$RESULT_ROOT/$STAMP"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""
SERVER_KILL_GROUP=0

stop_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    if [[ "$SERVER_KILL_GROUP" -eq 1 ]]; then
      kill -TERM "-$SERVER_PID" 2>/dev/null || true
    else
      kill "$SERVER_PID" 2>/dev/null || true
    fi
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
  SERVER_KILL_GROUP=0
}

cleanup() {
  stop_server
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
  echo "ETA_H2_ECHO_4X4_TRACE_MODE must be tls or plain" >&2
  exit 2
fi

if (( TOTAL_REQUESTS % CONNECTIONS != 0 )); then
  echo "ETA_H2_ECHO_4X4_TRACE_REQUESTS must be divisible by connections" >&2
  exit 2
fi

REQUESTS_PER_CONNECTION=$((TOTAL_REQUESTS / CONNECTIONS))
SERVER_CORE="${ETA_SERVER_LOAD_SERVER_CORE:-2}"
LOAD_CORE="${ETA_SERVER_LOAD_LOAD_CORE:-3}"

nix develop -c dune build \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_tls_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

PORT=$((24000 + RANDOM % 12000))
SERVER_LOG="$RESULT_DIR/server.log"
EVENT_TRACE="$RESULT_DIR/event.log"
SLOW_TRACE="$RESULT_DIR/slow-write.log"
PHASE_TRACE="$RESULT_DIR/phase.log"
STRACE_DIR="$RESULT_DIR/strace"
PROBE="_build/default/http-testsuite/test/server_load/h2_probe.exe"
CLIENT_TLS_ENV=()

if [[ "$MODE" == "tls" ]]; then
  PROBE="_build/default/http-testsuite/test/server_load/h2_tls_probe.exe"
  CLIENT_TLS_ENV=(ETA_H2_GAP_TLS_CA_FILE="$TMP_DIR/server/certs/ca.pem")
fi

server_cmd=("$PROBE")
if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
  server_cmd=(taskset -c "$SERVER_CORE" "${server_cmd[@]}")
fi

if bool_env ETA_H2_ECHO_4X4_STRACE_SERVER false; then
  if ! have_command strace; then
    echo "strace is required when ETA_H2_ECHO_4X4_STRACE_SERVER is enabled" >&2
    exit 2
  fi
  if ! have_command setsid; then
    echo "setsid is required when ETA_H2_ECHO_4X4_STRACE_SERVER is enabled" >&2
    exit 2
  fi
  mkdir -p "$STRACE_DIR"
  server_cmd=(
    strace -ff -ttt -T -yy
    -e trace=read,readv,recvfrom,recvmsg,write,writev,sendto,sendmsg,io_uring_enter,epoll_wait,epoll_pwait,poll,ppoll,pselect6,select
    -o "$STRACE_DIR/server"
    "${server_cmd[@]}"
  )
  server_cmd=(setsid "${server_cmd[@]}")
  SERVER_KILL_GROUP=1
fi

server_env=(
  ETA_H2_SLOW_WRITE_TRACE_PATH="$SLOW_TRACE"
  ETA_H2_SLOW_WRITE_TRACE_THRESHOLD_US="$THRESHOLD_US"
  ETA_H2_PHASE_TRACE_PATH="$PHASE_TRACE"
)
if [[ -n "${ETA_H2_ECHO_4X4_STRACE_EIO_BACKEND:-}" ]]; then
  server_env+=(EIO_BACKEND="$ETA_H2_ECHO_4X4_STRACE_EIO_BACKEND")
fi
if bool_env ETA_H2_ECHO_4X4_TRACE_EVENTS "$ENABLE_EVENT_TRACE"; then
  server_env+=(ETA_H2_ECHO_TRACE_PATH="$EVENT_TRACE")
fi

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
    _build/default/http-testsuite/test/server_load/h2_gap_client.exe
    127.0.0.1 "$PORT" "$REQUESTS_PER_CONNECTION" "$STREAMS_PER_CONNECTION"
    1 "$out" "$REQUEST_PATH"
  )
  if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
    client_cmd=(taskset -c "$LOAD_CORE" "${client_cmd[@]}")
  fi
  env \
    ETA_H2_GAP_METHOD="$REQUEST_METHOD" \
    ETA_H2_GAP_BODY_BYTES="$REQUEST_BODY_BYTES" \
    ETA_H2_GAP_TIMEOUT="$TIMEOUT" \
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

stop_server

if [[ "$failed" -ne 0 ]]; then
  echo "one or more custom clients failed" >&2
  exit 1
fi

python - "$RESULT_DIR" "$TOTAL_REQUESTS" "$THRESHOLD_US" "$SLOW_TRACE" "$PHASE_TRACE" "$EVENT_TRACE" "$REQUEST_METHOD" "$REQUEST_PATH" "$REQUEST_BODY_BYTES" "$EXPECTED_RESPONSE_BYTES" <<'PY'
import csv
from collections import defaultdict
import math
import os
import re
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
expected = int(sys.argv[2])
threshold_us = int(sys.argv[3])
slow_trace_path = Path(sys.argv[4])
phase_trace_path = Path(sys.argv[5])
event_trace_path = Path(sys.argv[6])
request_method = sys.argv[7]
request_path = sys.argv[8]
request_body_bytes = int(sys.argv[9])
expected_response_bytes = int(sys.argv[10])

rows = []
for path in sorted(result_dir.glob("client-*.tsv")):
    with path.open() as f:
        reader = csv.DictReader(f, delimiter="\t")
        rows.extend(dict(row, client_file=path.name) for row in reader)

def i(row, name):
    return int(row[name])

drop_initial_per_client = int(os.environ.get("ETA_H2_ECHO_4X4_TRACE_DROP_INITIAL_PER_CLIENT", "0") or "0")
valid_all = []
bad = 0
for row in rows:
    if row["error"] or i(row, "status") != 200 or i(row, "bytes") != expected_response_bytes:
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
    valid_all.append(
        {
            "client_file": row["client_file"],
            "index": i(row, "index"),
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

valid = [
    row
    for row in valid_all
    if row["index"] > drop_initial_per_client
]

def pct(values, percentile):
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

for key in [
    "total_us",
    "t0_t1_us",
    "t1_t2_us",
    "t2_t3_us",
    "tx_ready_to_t1_us",
    "rx_headers_to_t2_us",
    "rx_feed_us",
]:
    record_dist(key, [row[key] for row in valid])

slow_durations = []
slow_bytes = []
if slow_trace_path.exists():
    pattern = re.compile(r"bytes=(\d+) duration_us=(\d+)")
    for line in slow_trace_path.read_text().splitlines():
        match = pattern.search(line)
        if match:
            slow_bytes.append(int(match.group(1)))
            slow_durations.append(int(match.group(2)))

record_dist("slow_write", slow_durations)
metrics["slow_write_count"] = float(len(slow_durations))
metrics["slow_write_fraction"] = len(slow_durations) / expected if expected else 0.0
metrics["slow_write_median_bytes"] = pct(slow_bytes, 50)

strace_dir = result_dir / "strace"
strace_files = sorted(strace_dir.glob("server*"))
strace_name_durations = defaultdict(list)
strace_tcp_name_durations = defaultdict(list)
strace_lines = 0
strace_tcp_lines = 0
normal_syscall = re.compile(r"\d+\.\d+\s+([A-Za-z0-9_]+)\(.*<([0-9.]+)>$")
resumed_syscall = re.compile(r"\d+\.\d+\s+<\.\.\. ([A-Za-z0-9_]+) resumed>.*<([0-9.]+)>$")
for path in strace_files:
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        continue
    for line in lines:
        match = normal_syscall.search(line) or resumed_syscall.search(line)
        if not match:
            continue
        syscall = match.group(1)
        duration_us = float(match.group(2)) * 1_000_000.0
        strace_lines += 1
        strace_name_durations[syscall].append(duration_us)
        if "TCP:[" in line:
            strace_tcp_lines += 1
            strace_tcp_name_durations[syscall].append(duration_us)

def group_values(source, names):
    values = []
    for name in names:
        values.extend(source.get(name, []))
    return values

syscall_groups = {
    "read_syscall": ["read", "readv", "recvfrom", "recvmsg"],
    "write_syscall": ["write", "writev", "sendto", "sendmsg"],
    "wait_syscall": [
        "epoll_wait",
        "epoll_pwait",
        "poll",
        "ppoll",
        "pselect6",
        "select",
        "io_uring_enter",
    ],
    "io_uring_enter": ["io_uring_enter"],
}
for name, syscalls in syscall_groups.items():
    values = group_values(strace_name_durations, syscalls)
    tcp_values = group_values(strace_tcp_name_durations, syscalls)
    record_dist(f"strace_{name}", values)
    record_dist(f"strace_tcp_{name}", tcp_values)
    metrics[f"strace_{name}_count"] = float(len(values))
    metrics[f"strace_tcp_{name}_count"] = float(len(tcp_values))

metrics["strace_file_count"] = float(len(strace_files))
metrics["strace_duration_line_count"] = float(strace_lines)
metrics["strace_tcp_duration_line_count"] = float(strace_tcp_lines)

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
        try:
            if event == "h2_phase_ingress_read":
                entry.setdefault("ingress_started_us", int(fields["started_us"]))
                entry.setdefault("ingress_returned_us", int(fields["returned_us"]))
            elif event == "h2_phase_ingress_handle_start":
                entry.setdefault("ingress_handle_started_us", int(fields["started_us"]))
                entry.setdefault("ingress_queue_wait_us", int(fields["queue_wait_us"]))
            elif event == "h2_phase_request_accepted":
                entry.setdefault("accepted_us", int(fields["accepted_us"]))
            elif event == "h2_phase_response_start":
                entry.setdefault("response_start_us", int(fields["started_us"]))
            elif event == "h2_phase_write_job_start":
                entry.setdefault("write_job_started_us", int(fields["started_us"]))
                entry.setdefault("write_job_wait_us", int(fields["job_wait_us"]))
            elif event == "h2_phase_write_flow_complete":
                entry.setdefault("flow_complete_us", int(fields["completed_us"]))
                entry.setdefault("flow_write_us", int(fields["flow_write_us"]))
        except (KeyError, ValueError):
            pass

joined = []
required = [
    "ingress_returned_us",
    "accepted_us",
    "response_start_us",
    "flow_complete_us",
]
for row in valid:
    entry = phase.get((row["local_port"], row["stream_id"]))
    if not entry or any(name not in entry for name in required):
        continue
    joined_row = {
        **row,
        "t1_to_ingress_returned_us": entry["ingress_returned_us"] - row["t1_us"],
        "ingress_returned_to_accepted_us": entry["accepted_us"] - entry["ingress_returned_us"],
        "accepted_to_response_start_us": entry["response_start_us"] - entry["accepted_us"],
        "response_start_to_flow_complete_us": entry["flow_complete_us"] - entry["response_start_us"],
        "flow_complete_to_rx_headers_us": row["rx_headers_us"] - entry["flow_complete_us"],
        "t1_to_accepted_us": entry["accepted_us"] - row["t1_us"],
        "t1_to_response_start_us": entry["response_start_us"] - row["t1_us"],
        "t1_to_flow_complete_us": entry["flow_complete_us"] - row["t1_us"],
    }
    if "ingress_handle_started_us" in entry:
        joined_row["ingress_returned_to_handle_start_us"] = (
            entry["ingress_handle_started_us"] - entry["ingress_returned_us"]
        )
        joined_row["ingress_handle_start_to_accepted_us"] = (
            entry["accepted_us"] - entry["ingress_handle_started_us"]
        )
        joined_row["ingress_queue_wait_us"] = entry["ingress_queue_wait_us"]
    if "write_job_started_us" in entry:
        joined_row["response_start_to_write_job_start_us"] = (
            entry["write_job_started_us"] - entry["response_start_us"]
        )
        joined_row["write_job_start_to_flow_complete_us"] = (
            entry["flow_complete_us"] - entry["write_job_started_us"]
        )
        joined_row["write_job_wait_us"] = entry["write_job_wait_us"]
    if "flow_write_us" in entry:
        joined_row["flow_write_us"] = entry["flow_write_us"]
    joined.append(joined_row)

for key in [
    "t1_to_ingress_returned_us",
    "ingress_returned_to_accepted_us",
    "accepted_to_response_start_us",
    "response_start_to_flow_complete_us",
    "flow_complete_to_rx_headers_us",
    "t1_to_accepted_us",
    "t1_to_response_start_us",
    "t1_to_flow_complete_us",
    "ingress_returned_to_handle_start_us",
    "ingress_handle_start_to_accepted_us",
    "ingress_queue_wait_us",
    "response_start_to_write_job_start_us",
    "write_job_start_to_flow_complete_us",
    "write_job_wait_us",
    "flow_write_us",
]:
    record_dist(key, [row[key] for row in joined if key in row])

handler_read_us = []
handler_body_bytes = []
handler_copy_bytes = []
body_chunk_reader_wait_us = []
body_chunk_copy_us = []
body_chunk_bytes = []
body_eof_wait_us = []
body_read_return_wait_us = []
event_lines = 0
if event_trace_path.exists():
    for line in event_trace_path.read_text().splitlines():
        event, fields = parse_kv_line(line)
        if event is None:
            continue
        event_lines += 1
        try:
            if event == "echo_handler":
                handler_read_us.append(int(fields["request_body_read_us"]))
                handler_body_bytes.append(int(fields["body_bytes"]))
                handler_copy_bytes.append(int(fields["handler_copy_bytes"]))
            elif event == "h2_request_body_chunk":
                body_chunk_reader_wait_us.append(int(fields["reader_wait_us"]))
                body_chunk_copy_us.append(int(fields["copy_us"]))
                body_chunk_bytes.append(int(fields["bytes"]))
            elif event == "h2_request_body_eof":
                body_eof_wait_us.append(int(fields["eof_wait_us"]))
            elif event == "h2_request_body_read_return":
                body_read_return_wait_us.append(int(fields["read_wait_us"]))
        except (KeyError, ValueError):
            pass

for name, values in [
    ("handler_request_body_read", handler_read_us),
    ("handler_body_bytes", handler_body_bytes),
    ("handler_copy_bytes", handler_copy_bytes),
    ("body_chunk_reader_wait", body_chunk_reader_wait_us),
    ("body_chunk_copy", body_chunk_copy_us),
    ("body_chunk_bytes", body_chunk_bytes),
    ("body_eof_wait", body_eof_wait_us),
    ("body_read_return_wait", body_read_return_wait_us),
]:
    record_dist(name, values)

metrics["rows"] = float(len(rows))
metrics["valid_before_drop"] = float(len(valid_all))
metrics["valid"] = float(len(valid))
metrics["dropped_initial"] = float(len(valid_all) - len(valid))
metrics["bad"] = float(bad)
metrics["success"] = 1.0 if len(valid_all) == expected and bad == 0 else 0.0
metrics["phase_trace_lines"] = float(phase_lines)
metrics["phase_keys"] = float(len(phase))
metrics["phase_joined"] = float(len(joined))
metrics["phase_missing"] = float(len(valid) - len(joined))
metrics["phase_ingress_handle_joined"] = float(
    sum(1 for row in joined if "ingress_returned_to_handle_start_us" in row)
)
metrics["phase_write_job_joined"] = float(
    sum(1 for row in joined if "write_job_start_to_flow_complete_us" in row)
)
metrics["event_trace_lines"] = float(event_lines)
metrics["handler_trace_count"] = float(len(handler_read_us))
metrics["body_chunk_count"] = float(len(body_chunk_reader_wait_us))
metrics["body_eof_count"] = float(len(body_eof_wait_us))

print(f"trace_dir\t{result_dir}")
print(f"threshold_us\t{threshold_us}")
print(f"request_method\t{request_method}")
print(f"request_path\t{request_path}")
print(f"request_body_bytes\t{request_body_bytes}")
print(f"expected_response_bytes\t{expected_response_bytes}")
print(f"drop_initial_per_client\t{drop_initial_per_client}")
for name in sorted(metrics):
    value = metrics[name]
    if value.is_integer():
        print(f"{name}\t{int(value)}")
    else:
        print(f"{name}\t{value:.6f}")

print(
    "top_total_us\tclient_file\tlocal_port\tstream_id\tt1_flow_us\t"
    "response_write_start_us\twrite_flow_us\tflow_rx_headers_us\tt2_t3_us"
)
for row in sorted(joined, key=lambda item: item["total_us"], reverse=True)[:20]:
    print(
        f"{row['total_us']}\t{row['client_file']}\t{row['local_port']}\t"
        f"{row['stream_id']}\t{row['t1_to_flow_complete_us']}\t"
        f"{row.get('response_start_to_write_job_start_us', -1)}\t"
        f"{row.get('flow_write_us', -1)}\t"
        f"{row['flow_complete_to_rx_headers_us']}\t{row['t2_t3_us']}"
    )

for name in sorted(metrics):
    print(f"METRIC h2_echo_4x4_trace_{name}={metrics[name]:.6f}")
PY
