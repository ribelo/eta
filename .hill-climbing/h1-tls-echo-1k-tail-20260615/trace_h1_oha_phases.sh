#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H1_OHA_TRACE_REQUESTS:-24000}"
CONCURRENCY="${ETA_H1_OHA_TRACE_CONCURRENCY:-16}"
TIMEOUT="${ETA_H1_OHA_TRACE_TIMEOUT:-10s}"
MODE="${ETA_H1_OHA_TRACE_MODE:-tls}"
ENDPOINTS="${ETA_H1_OHA_TRACE_ENDPOINTS:-echo_1k static_1k}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/oha-phase-results/$STAMP"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup_server() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  SERVER_PID=""
}

cleanup() {
  cleanup_server
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

endpoint_shape() {
  local endpoint="$1"
  case "$endpoint" in
    echo_1k) printf 'POST\t/echo\t1024\t1024\n' ;;
    static_1k) printf 'GET\t/static/1k.bin\t0\t1024\n' ;;
    root) printf 'GET\t/\t0\t0\n' ;;
    post_user) printf 'POST\t/user\t0\t0\n' ;;
    post_user_1k) printf 'POST\t/user\t1024\t0\n' ;;
    user_id) printf 'GET\t/user/123\t0\t3\n' ;;
    *)
      echo "unknown endpoint: $endpoint" >&2
      exit 2
      ;;
  esac
}

cd "$ROOT"
mkdir -p "$RESULT_DIR"

if [[ "$MODE" != "tls" && "$MODE" != "plain" ]]; then
  echo "ETA_H1_OHA_TRACE_MODE must be tls or plain" >&2
  exit 2
fi

if ! have_command oha; then
  echo "oha is required for this trace" >&2
  exit 2
fi

nix develop -c dune build \
  http-testsuite/test/server_load/h1_probe.exe \
  http-testsuite/test/server_load/h1_tls_probe.exe

BODY_1K="$TMP_DIR/body-echo-1k.bin"
python -c 'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b"x" * 1024)' "$BODY_1K"

SERVER_CORE="${ETA_SERVER_LOAD_SERVER_CORE:-2}"
LOAD_CORE="${ETA_SERVER_LOAD_LOAD_CORE:-3}"

start_server() {
  local endpoint="$1"
  cleanup_server
  local port=$((24000 + RANDOM % 12000))
  local server_tmp="$TMP_DIR/server-$endpoint"
  local server_log="$RESULT_DIR/$MODE-$endpoint-server.log"
  local phase_trace="$RESULT_DIR/$MODE-$endpoint-phase.log"
  local event_trace="$RESULT_DIR/$MODE-$endpoint-event.log"
  local tls_trace="$RESULT_DIR/$MODE-$endpoint-tls-io.log"
  mkdir -p "$server_tmp"

  local probe="_build/default/http-testsuite/test/server_load/h1_probe.exe"
  if [[ "$MODE" == "tls" ]]; then
    probe="_build/default/http-testsuite/test/server_load/h1_tls_probe.exe"
  fi

  local server_cmd=("$probe")
  if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
    server_cmd=(taskset -c "$SERVER_CORE" "${server_cmd[@]}")
  fi

  env \
    ETA_H1_PHASE_TRACE_PATH="$phase_trace" \
    ETA_HTTP_ECHO_TRACE_PATH="$event_trace" \
    ETA_TLS_IO_TRACE_PATH="$tls_trace" \
    "${server_cmd[@]}" "$port" "$server_tmp" >"$server_log" 2>&1 &
  SERVER_PID="$!"

  local ready=0
  for _ in $(seq 1 200); do
    if grep -q "READY $port" "$server_log"; then
      ready=1
      break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$server_log" >&2
      exit 1
    fi
    sleep 0.05
  done

  if [[ "$ready" -ne 1 ]]; then
    cat "$server_log" >&2
    exit 1
  fi

  printf '%s' "$port"
}

run_oha_case() {
  local endpoint="$1"
  local method="$2"
  local path="$3"
  local body_bytes="$4"
  local port="$5"
  local raw="$RESULT_DIR/$MODE-$endpoint-oha.json"
  local err="$RESULT_DIR/$MODE-$endpoint-oha.err"
  local scheme="http"
  local tls_flags=()
  if [[ "$MODE" == "tls" ]]; then
    scheme="https"
    tls_flags=(--insecure)
  fi
  local url="${scheme}://127.0.0.1:${port}${path}"
  local cmd=(
    oha
    --no-tui
    --output-format json
    --redirect 0
    --disable-compression
    --connect-timeout 2s
    -t "$TIMEOUT"
    -c "$CONCURRENCY"
    -n "$REQUESTS"
    --http-version 1.1
    "${tls_flags[@]}"
  )
  if [[ "$method" == "POST" ]]; then
    cmd+=(-m POST -T text/plain)
    if [[ "$body_bytes" -gt 0 ]]; then
      cmd+=(-D "$BODY_1K")
    fi
  fi
  cmd+=("$url")

  local runner=()
  if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
    runner=(taskset -c "$LOAD_CORE")
  fi

  env NO_COLOR=false "${runner[@]}" "${cmd[@]}" >"$raw" 2>"$err"
}

for endpoint in $ENDPOINTS; do
  IFS=$'\t' read -r method path body_bytes _expected_bytes < <(endpoint_shape "$endpoint")
  echo "$MODE $endpoint: H1 oha phase trace" >&2
  port="$(start_server "$endpoint")"
  run_oha_case "$endpoint" "$method" "$path" "$body_bytes" "$port"
  cleanup_server
done

python - "$RESULT_DIR" "$MODE" "$REQUESTS" $ENDPOINTS <<'PY'
import json
import math
import re
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
mode = sys.argv[2]
requests = int(sys.argv[3])
endpoints = sys.argv[4:]

expected_bytes = {
    "echo_1k": 1024,
    "static_1k": 1024,
    "root": 0,
    "post_user": 0,
    "post_user_1k": 0,
    "user_id": 3,
}

def pct(values, percentile):
    values = list(values)
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1))
    return float(ordered[index])

def record_dist(metrics, prefix, values):
    values = list(values)
    metrics[f"{prefix}_p50_us"] = pct(values, 50)
    metrics[f"{prefix}_p95_us"] = pct(values, 95)
    metrics[f"{prefix}_p99_us"] = pct(values, 99)
    metrics[f"{prefix}_p999_us"] = pct(values, 99.9)
    metrics[f"{prefix}_max_us"] = float(max(values) if values else 0)

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

all_metrics = {}
rows = []

for endpoint in endpoints:
    metrics = {}
    raw_path = result_dir / f"{mode}-{endpoint}-oha.json"
    raw = json.loads(raw_path.read_text())
    summary = raw.get("summary", {})
    latency = raw.get("latencyPercentiles", {})
    status_dist = raw.get("statusCodeDistribution", {})
    error_dist = raw.get("errorDistribution", {})
    total_data = int(float(summary.get("totalData") or 0))
    expected_total_data = expected_bytes[endpoint] * requests
    status_200 = int(status_dist.get("200", 0) or 0)
    errors = sum(int(v or 0) for v in error_dist.values())
    success = (
        int(summary.get("totalRequests", requests) or requests) == requests
        and status_200 == requests
        and errors == 0
        and float(summary.get("successRate") or 0.0) == 1.0
        and total_data == expected_total_data
    )
    metrics["oha_p50_us"] = float(latency.get("p50") or 0.0) * 1_000_000.0
    metrics["oha_p95_us"] = float(latency.get("p95") or 0.0) * 1_000_000.0
    metrics["oha_p99_us"] = float(latency.get("p99") or 0.0) * 1_000_000.0
    metrics["oha_p999_us"] = float(latency.get("p99.9") or 0.0) * 1_000_000.0
    metrics["oha_max_us"] = float(summary.get("slowest") or 0.0) * 1_000_000.0
    metrics["oha_rps"] = float(summary.get("requestsPerSec") or 0.0)
    metrics["success"] = 1.0 if success else 0.0

    phase = {}
    phase_lines = 0
    phase_path = result_dir / f"{mode}-{endpoint}-phase.log"
    if phase_path.exists():
        for line in phase_path.read_text().splitlines():
            event, fields = parse_kv_line(line)
            if event is None:
                continue
            phase_lines += 1
            try:
                connection_id = fields.get("connection_id", "")
                ordinal = int(fields.get("ordinal", "-1"))
            except ValueError:
                continue
            if not connection_id or ordinal <= 0:
                continue
            entry = phase.setdefault((connection_id, ordinal), {})
            try:
                if event == "h1_phase_request_head":
                    entry["request_head_read_us"] = int(fields["read_us"])
                    entry["request_head_completed_us"] = int(fields["completed_us"])
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
                    entry["response_write_us"] = entry.get("response_write_us", 0) + int(fields["write_us"])
                elif event == "h1_phase_request_complete":
                    entry["request_complete_us"] = int(fields["completed_us"])
            except (KeyError, ValueError):
                pass

    event_lines = 0
    event_path = result_dir / f"{mode}-{endpoint}-event.log"
    if event_path.exists():
        for line in event_path.read_text().splitlines():
            event, fields = parse_kv_line(line)
            if event != "echo_handler":
                continue
            event_lines += 1
            request_id = fields.get("request_id", "")
            match = re.search(r"^(.*)/request-(\d+)$", request_id)
            if not match:
                continue
            try:
                connection_id = fields.get("connection_id", match.group(1))
                ordinal = int(match.group(2))
                entry = phase.setdefault((connection_id, ordinal), {})
                entry["handler_request_body_read_us"] = int(fields["request_body_read_us"])
                entry["handler_body_bytes"] = int(fields["body_bytes"])
                entry["handler_copy_bytes"] = int(fields["handler_copy_bytes"])
            except (KeyError, ValueError):
                pass

    joined = []
    required = [
        "request_head_read_us",
        "accepted_us",
        "handler_start_us",
        "handler_done_us",
        "write_start_us",
        "write_complete_us",
        "request_complete_us",
    ]
    for entry in phase.values():
        if all(name in entry for name in required):
            row = {
                "request_head_read_us": entry["request_head_read_us"],
                "accepted_to_handler_start_us": entry["handler_start_us"] - entry["accepted_us"],
                "handler_us": entry["handler_us"],
                "handler_to_write_start_us": entry["write_start_us"] - entry["handler_done_us"],
                "response_write_us": entry["write_complete_us"] - entry["write_start_us"],
                "request_complete_after_write_us": entry["request_complete_us"] - entry["write_complete_us"],
                "server_request_us": entry["request_complete_us"] - entry["request_head_completed_us"],
                "write_bytes": entry.get("write_bytes", 0),
            }
            for name in ["handler_request_body_read_us", "handler_body_bytes", "handler_copy_bytes"]:
                if name in entry:
                    row[name] = entry[name]
            joined.append(row)

    for name in [
        "request_head_read_us",
        "accepted_to_handler_start_us",
        "handler_us",
        "handler_request_body_read_us",
        "handler_body_bytes",
        "handler_copy_bytes",
        "handler_to_write_start_us",
        "response_write_us",
        "request_complete_after_write_us",
        "server_request_us",
        "write_bytes",
    ]:
        record_dist(metrics, name, [row[name] for row in joined if name in row])

    tls_raw_reads = []
    tls_raw_writes = []
    tls_path = result_dir / f"{mode}-{endpoint}-tls-io.log"
    if tls_path.exists():
        for line in tls_path.read_text().splitlines():
            event, fields = parse_kv_line(line)
            try:
                if event == "tls_raw_read":
                    tls_raw_reads.append(int(fields["wait_us"]))
                elif event == "tls_raw_write":
                    tls_raw_writes.append(int(fields["write_us"]))
            except (KeyError, ValueError):
                pass
    record_dist(metrics, "tls_raw_read", tls_raw_reads)
    record_dist(metrics, "tls_raw_write", tls_raw_writes)
    metrics["tls_raw_read_count"] = float(len(tls_raw_reads))
    metrics["tls_raw_write_count"] = float(len(tls_raw_writes))
    metrics["phase_trace_lines"] = float(phase_lines)
    metrics["phase_keys"] = float(len(phase))
    metrics["phase_joined"] = float(len(joined))
    metrics["event_trace_lines"] = float(event_lines)

    row = {
        "mode": mode,
        "endpoint": endpoint,
        "oha_p99_us": metrics["oha_p99_us"],
        "server_request_p99_us": metrics["server_request_us_p99_us"],
        "response_write_p99_us": metrics["response_write_us_p99_us"],
        "tls_raw_write_p99_us": metrics["tls_raw_write_p99_us"],
        "handler_body_read_p99_us": metrics["handler_request_body_read_us_p99_us"],
        "success": metrics["success"],
    }
    rows.append(row)

    for name, value in metrics.items():
        all_metrics[f"h1_oha_trace_{mode}_{endpoint}_{name}"] = value

print(f"trace_dir\t{result_dir}")
print("mode\tendpoint\toha_p99_us\tserver_request_p99_us\tresponse_write_p99_us\ttls_raw_write_p99_us\thandler_body_read_p99_us\tsuccess")
for row in rows:
    print(
        f"{row['mode']}\t{row['endpoint']}\t{row['oha_p99_us']:.3f}\t"
        f"{row['server_request_p99_us']:.3f}\t{row['response_write_p99_us']:.3f}\t"
        f"{row['tls_raw_write_p99_us']:.3f}\t{row['handler_body_read_p99_us']:.3f}\t"
        f"{row['success']:.0f}"
    )

for name in sorted(all_metrics):
    print(f"METRIC {name}={all_metrics[name]:.6f}")
PY
