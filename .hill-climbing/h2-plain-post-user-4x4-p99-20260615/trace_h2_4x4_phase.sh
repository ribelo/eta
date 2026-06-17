#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"

REQUESTS="${ETA_H2_POST_4X4_PHASE_REQUESTS:-12000}"
CONNECTIONS="${ETA_H2_POST_4X4_PHASE_CONNECTIONS:-4}"
STREAMS="${ETA_H2_POST_4X4_PHASE_STREAMS:-4}"
TIMEOUT="${ETA_H2_POST_4X4_PHASE_TIMEOUT:-10s}"
ENDPOINT="${ETA_H2_POST_4X4_PHASE_ENDPOINT:-post_user}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/results/phase-$ENDPOINT-$STAMP"
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

free_port() {
  python - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

cd "$ROOT"
mkdir -p "$RESULT_DIR"

if ! have_command oha; then
  echo "oha is required for this trace" >&2
  exit 2
fi

nix develop -c dune build http-testsuite/test/server_load/h2_probe.exe

BODY_1K="$TMP_DIR/body-echo-1k.bin"
python -c 'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b"x" * 1024)' "$BODY_1K"

case "$ENDPOINT" in
  root)
    METHOD="GET"
    PATH_ONLY="/"
    BODY_FILE=""
    EXPECTED_RESPONSE_BYTES="0"
    ;;
  user_id)
    METHOD="GET"
    PATH_ONLY="/user/123"
    BODY_FILE=""
    EXPECTED_RESPONSE_BYTES="3"
    ;;
  post_user)
    METHOD="POST"
    PATH_ONLY="/user"
    BODY_FILE=""
    EXPECTED_RESPONSE_BYTES="0"
    ;;
  static_1k)
    METHOD="GET"
    PATH_ONLY="/static/1k.bin"
    BODY_FILE=""
    EXPECTED_RESPONSE_BYTES="1024"
    ;;
  echo_1k)
    METHOD="POST"
    PATH_ONLY="/echo"
    BODY_FILE="$BODY_1K"
    EXPECTED_RESPONSE_BYTES="1024"
    ;;
  *)
    echo "unknown ETA_H2_POST_4X4_PHASE_ENDPOINT: $ENDPOINT" >&2
    exit 2
    ;;
esac

SERVER_CORE="${ETA_SERVER_LOAD_SERVER_CORE:-2}"
LOAD_CORE="${ETA_SERVER_LOAD_LOAD_CORE:-3}"
PORT="$(free_port)"
SERVER_TMP="$TMP_DIR/server"
SERVER_LOG="$RESULT_DIR/server.log"
PHASE_TRACE="$RESULT_DIR/h2-phase.log"
mkdir -p "$SERVER_TMP"

server_cmd=("_build/default/http-testsuite/test/server_load/h2_probe.exe" "$PORT" "$SERVER_TMP")
if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
  server_cmd=(taskset -c "$SERVER_CORE" "${server_cmd[@]}")
fi

ETA_H2_PHASE_TRACE_PATH="$PHASE_TRACE" "${server_cmd[@]}" >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

for _ in $(seq 1 200); do
  if grep -q "READY $PORT" "$SERVER_LOG"; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Eta H2C server exited before ready" >&2
    sed -n '1,160p' "$SERVER_LOG" >&2
    exit 1
  fi
  sleep 0.05
done

if ! grep -q "READY $PORT" "$SERVER_LOG"; then
  echo "Eta H2C server did not become ready" >&2
  sed -n '1,160p' "$SERVER_LOG" >&2
  exit 1
fi

runner=()
if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
  runner=(taskset -c "$LOAD_CORE")
fi

RAW="$RESULT_DIR/oha.json"
ERR="$RESULT_DIR/oha.err"
cmd=(
  oha
  --no-tui
  --output-format json
  --redirect 0
  --disable-compression
  --connect-timeout 2s
  -t "$TIMEOUT"
  -c "$CONNECTIONS"
  -p "$STREAMS"
  -n "$REQUESTS"
  --http-version 2
)
if [[ "$METHOD" == "POST" ]]; then
  cmd+=(-m POST -T text/plain)
  if [[ -n "$BODY_FILE" ]]; then
    cmd+=(-D "$BODY_FILE")
  fi
fi
cmd+=("http://127.0.0.1:${PORT}${PATH_ONLY}")

env NO_COLOR=false "${runner[@]}" "${cmd[@]}" >"$RAW" 2>"$ERR"

sleep 0.3

python - "$RESULT_DIR" "$RAW" "$PHASE_TRACE" "$REQUESTS" "$ENDPOINT" "$EXPECTED_RESPONSE_BYTES" <<'PY'
import json
import math
import re
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
raw_path = Path(sys.argv[2])
phase_path = Path(sys.argv[3])
requests = int(sys.argv[4])
endpoint = sys.argv[5]
expected_response_bytes = int(sys.argv[6])

def number(value, default=0.0):
    if value is None:
        return default
    return float(value)

def pct(values, percentile):
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = math.ceil((percentile / 100.0) * len(ordered)) - 1
    rank = max(0, min(rank, len(ordered) - 1))
    return ordered[rank]

def parse_fields(line):
    return dict(re.findall(r"([A-Za-z0-9_]+)=([^ ]+)", line))

with raw_path.open() as f:
    raw = json.load(f)
summary = raw.get("summary", {})
latency = raw.get("latencyPercentiles", {})
status_dist = raw.get("statusCodeDistribution", {})
error_dist = raw.get("errorDistribution", {})
status_200 = int(status_dist.get("200", 0) or 0)
errors = sum(int(v) for v in error_dist.values()) if isinstance(error_dist, dict) else 0
total_data = int(round(number(summary.get("totalData"))))
success = (
    status_200 == requests
    and errors == 0
    and abs(number(summary.get("successRate")) - 1.0) < 0.000001
    and total_data == requests * expected_response_bytes
)

accepted = {}
response_start = {}
write_complete_time = {}
write_ready_wait = []
write_job_wait = []
flow_write = []
response_write = []
ingress_read_wait = []
ingress_queue_wait = []

if phase_path.exists():
    for line in phase_path.read_text().splitlines():
        fields = parse_fields(line)
        if not fields:
            continue
        key = (fields.get("connection_id"), fields.get("stream_id"))
        if line.startswith("h2_phase_ingress_read"):
            stream_id = int(fields.get("stream_id", "-1"))
            if stream_id > 0:
                ingress_read_wait.append(float(fields.get("wait_us", "0")))
        elif line.startswith("h2_phase_ingress_handle_start"):
            ingress_queue_wait.append(float(fields.get("queue_wait_us", "0")))
        elif line.startswith("h2_phase_request_accepted"):
            accepted[key] = int(fields.get("accepted_us", "0"))
        elif line.startswith("h2_phase_response_start"):
            response_start[key] = int(fields.get("started_us", "0"))
        elif line.startswith("h2_phase_write_ready"):
            write_ready_wait.append(float(fields.get("wait_us", "0")))
        elif line.startswith("h2_phase_write_job_start"):
            write_job_wait.append(float(fields.get("job_wait_us", "0")))
        elif line.startswith("h2_phase_write_flow_complete"):
            flow_write.append(float(fields.get("flow_write_us", "0")))
        elif line.startswith("h2_phase_write_complete"):
            response_write.append(float(fields.get("response_write_us", "0")))
            write_complete_time[key] = int(fields.get("completed_us", "0"))

accepted_to_complete = [
    write_complete_time[key] - started
    for key, started in accepted.items()
    if key in write_complete_time and write_complete_time[key] >= started
]
response_start_to_complete = [
    write_complete_time[key] - started
    for key, started in response_start.items()
    if key in write_complete_time and write_complete_time[key] >= started
]

prefix = f"h2_plain_{endpoint}_4x4_phase"
metrics = {
    f"{prefix}_success": 1.0 if success else 0.0,
    f"{prefix}_client_rps": number(summary.get("requestsPerSec")),
    f"{prefix}_client_p50_us": number(latency.get("p50")) * 1_000_000.0,
    f"{prefix}_client_p99_us": number(latency.get("p99")) * 1_000_000.0,
    f"{prefix}_trace_requests": float(len(accepted_to_complete)),
    f"{prefix}_ingress_read_p50_us": pct(ingress_read_wait, 50),
    f"{prefix}_ingress_read_p99_us": pct(ingress_read_wait, 99),
    f"{prefix}_ingress_queue_p50_us": pct(ingress_queue_wait, 50),
    f"{prefix}_ingress_queue_p99_us": pct(ingress_queue_wait, 99),
    f"{prefix}_write_ready_p50_us": pct(write_ready_wait, 50),
    f"{prefix}_write_ready_p99_us": pct(write_ready_wait, 99),
    f"{prefix}_write_job_wait_p50_us": pct(write_job_wait, 50),
    f"{prefix}_write_job_wait_p99_us": pct(write_job_wait, 99),
    f"{prefix}_flow_write_p50_us": pct(flow_write, 50),
    f"{prefix}_flow_write_p99_us": pct(flow_write, 99),
    f"{prefix}_response_write_p50_us": pct(response_write, 50),
    f"{prefix}_response_write_p99_us": pct(response_write, 99),
    f"{prefix}_accepted_to_complete_p50_us": pct(accepted_to_complete, 50),
    f"{prefix}_accepted_to_complete_p99_us": pct(accepted_to_complete, 99),
    f"{prefix}_response_start_to_complete_p50_us": pct(response_start_to_complete, 50),
    f"{prefix}_response_start_to_complete_p99_us": pct(response_start_to_complete, 99),
}

with (result_dir / "summary.json").open("w") as f:
    json.dump(metrics, f, indent=2, sort_keys=True)
    f.write("\n")

print(f"RESULT_DIR {result_dir}")
for name in sorted(metrics):
    print(f"METRIC {name}={metrics[name]:.9g}")
PY
