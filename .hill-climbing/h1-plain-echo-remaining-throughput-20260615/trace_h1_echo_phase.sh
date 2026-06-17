#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"

REQUESTS="${ETA_H1_ECHO_PHASE_REQUESTS:-8000}"
CONCURRENCY="${ETA_H1_ECHO_PHASE_CONCURRENCY:-16}"
TIMEOUT="${ETA_H1_ECHO_PHASE_TIMEOUT:-10s}"
ENDPOINT="${ETA_H1_ECHO_PHASE_ENDPOINT:-echo_1k}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/results/trace-phase-$STAMP"
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
mkdir -p "$RESULT_DIR"

if ! have_command oha; then
  echo "oha is required for this trace" >&2
  exit 2
fi

nix develop -c dune build http-testsuite/test/server_load/h1_probe.exe

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
    echo "unknown ETA_H1_ECHO_PHASE_ENDPOINT: $ENDPOINT" >&2
    exit 2
    ;;
esac

SERVER_CORE="${ETA_SERVER_LOAD_SERVER_CORE:-2}"
LOAD_CORE="${ETA_SERVER_LOAD_LOAD_CORE:-3}"
PORT="$(
  python - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
SERVER_TMP="$TMP_DIR/server"
SERVER_LOG="$RESULT_DIR/server.log"
TRACE_PATH="$RESULT_DIR/h1-phase.log"
mkdir -p "$SERVER_TMP"

server_cmd=("_build/default/http-testsuite/test/server_load/h1_probe.exe" "$PORT" "$SERVER_TMP")
if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
  server_cmd=(taskset -c "$SERVER_CORE" "${server_cmd[@]}")
fi

ETA_H1_PHASE_TRACE_PATH="$TRACE_PATH" "${server_cmd[@]}" >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

for _ in $(seq 1 200); do
  if grep -q "READY $PORT" "$SERVER_LOG"; then
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Eta H1 server exited before ready" >&2
    sed -n '1,160p' "$SERVER_LOG" >&2
    exit 1
  fi
  sleep 0.05
done

if ! grep -q "READY $PORT" "$SERVER_LOG"; then
  echo "Eta H1 server did not become ready" >&2
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
  -c "$CONCURRENCY"
  -n "$REQUESTS"
  --http-version 1.1
)
if [[ "$METHOD" == "POST" ]]; then
  cmd+=(-m POST -T text/plain)
  if [[ -n "$BODY_FILE" ]]; then
    cmd+=(-D "$BODY_FILE")
  fi
fi
cmd+=("http://127.0.0.1:${PORT}${PATH_ONLY}")

env NO_COLOR=false "${runner[@]}" "${cmd[@]}" >"$RAW" 2>"$ERR"

# Let keep-alive connection fibers observe EOF and flush their per-connection
# trace buffers before the probe process is terminated by cleanup.
sleep 0.3

python - "$RESULT_DIR" "$RAW" "$TRACE_PATH" "$REQUESTS" "$ENDPOINT" "$PATH_ONLY" "$EXPECTED_RESPONSE_BYTES" <<'PY'
import json
import math
import re
import statistics
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
raw_path = Path(sys.argv[2])
trace_path = Path(sys.argv[3])
requests = int(sys.argv[4])
endpoint = sys.argv[5]
target_path = sys.argv[6]
expected_response_bytes = int(sys.argv[7])

def number(value, default=0.0):
    if value is None:
        return default
    return float(value)

def percentile(values, pct):
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = math.ceil((pct / 100.0) * len(ordered)) - 1
    rank = max(0, min(rank, len(ordered) - 1))
    return ordered[rank]

def parse_fields(line):
    fields = {}
    for key, value in re.findall(r"([A-Za-z0-9_]+)=([^ ]+)", line):
        fields[key] = value
    return fields

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

head_us = []
handler_us = []
write_us = []
complete_us = {}
accepted_us = {}
body_initial = []

if trace_path.exists():
    for line in trace_path.read_text().splitlines():
        fields = parse_fields(line)
        if not fields:
            continue
        key = (fields.get("connection_id"), fields.get("ordinal"))
        if line.startswith("h1_phase_request_head"):
            if fields.get("target") == target_path:
                head_us.append(float(fields.get("read_us", "0")))
                body_initial.append(int(fields.get("body_initial_bytes", "0")))
        elif line.startswith("h1_phase_request_accepted"):
            accepted_us[key] = int(fields.get("accepted_us", "0"))
        elif line.startswith("h1_phase_handler_done"):
            handler_us.append(float(fields.get("handler_us", "0")))
        elif line.startswith("h1_phase_response_write_complete"):
            write_us.append(float(fields.get("write_us", "0")))
        elif line.startswith("h1_phase_request_complete"):
            complete_us[key] = int(fields.get("completed_us", "0"))

accepted_to_complete = [
    complete_us[key] - accepted
    for key, accepted in accepted_us.items()
    if key in complete_us and complete_us[key] >= accepted
]

full_initial = sum(1 for value in body_initial if value >= 1024)
prefix = f"h1_plain_{endpoint}_phase"
metrics = {
    f"{prefix}_success": 1.0 if success else 0.0,
    f"{prefix}_client_rps": number(summary.get("requestsPerSec")),
    f"{prefix}_client_p50_us": number(latency.get("p50")) * 1_000_000.0,
    f"{prefix}_client_p99_us": number(latency.get("p99")) * 1_000_000.0,
    f"{prefix}_trace_requests": float(len(handler_us)),
    f"{prefix}_head_p50_us": percentile(head_us, 50),
    f"{prefix}_head_p99_us": percentile(head_us, 99),
    f"{prefix}_handler_p50_us": percentile(handler_us, 50),
    f"{prefix}_handler_p99_us": percentile(handler_us, 99),
    f"{prefix}_write_p50_us": percentile(write_us, 50),
    f"{prefix}_write_p99_us": percentile(write_us, 99),
    f"{prefix}_accepted_to_complete_p50_us": percentile(accepted_to_complete, 50),
    f"{prefix}_accepted_to_complete_p99_us": percentile(accepted_to_complete, 99),
    f"{prefix}_full_initial_body_ratio": (
        full_initial / len(body_initial) if body_initial else 0.0
    ),
}

if endpoint == "echo_1k":
    alias_prefix = "h1_plain_echo_phase"
    suffixes = [
        "success",
        "client_rps",
        "client_p50_us",
        "client_p99_us",
        "trace_requests",
        "head_p50_us",
        "head_p99_us",
        "handler_p50_us",
        "handler_p99_us",
        "write_p50_us",
        "write_p99_us",
        "accepted_to_complete_p50_us",
        "accepted_to_complete_p99_us",
        "full_initial_body_ratio",
    ]
    for suffix in suffixes:
        metrics[f"{alias_prefix}_{suffix}"] = metrics[f"{prefix}_{suffix}"]

with (result_dir / "summary.json").open("w") as f:
    json.dump(metrics, f, indent=2, sort_keys=True)
    f.write("\n")

print(f"RESULT_DIR {result_dir}")
for name in sorted(metrics):
    print(f"METRIC {name}={metrics[name]:.9g}")
PY
