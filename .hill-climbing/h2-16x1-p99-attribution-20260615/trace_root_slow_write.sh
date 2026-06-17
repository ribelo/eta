#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_16X1_TRACE_REQUESTS:-24000}"
TIMEOUT="${ETA_H2_16X1_TRACE_TIMEOUT:-10s}"
CONNECTIONS="${ETA_H2_16X1_CONNECTIONS:-16}"
STREAMS="${ETA_H2_16X1_STREAMS:-1}"
MODE="${ETA_H2_16X1_TRACE_MODE:-tls}"
THRESHOLD_US="${ETA_H2_SLOW_WRITE_TRACE_THRESHOLD_US:-500}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/slow-write-results/$STAMP"
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
SLOW_TRACE="$RESULT_DIR/slow-write.log"
PROBE="_build/default/http-testsuite/test/server_load/h2_tls_probe.exe"
SCHEME="https"
TLS_FLAGS=(--insecure)
if [[ "$MODE" == "plain" ]]; then
  PROBE="_build/default/http-testsuite/test/server_load/h2_probe.exe"
  SCHEME="http"
  TLS_FLAGS=()
fi

ETA_H2_SLOW_WRITE_TRACE_PATH="$SLOW_TRACE" \
ETA_H2_SLOW_WRITE_TRACE_THRESHOLD_US="$THRESHOLD_US" \
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

python - "$RESULT_DIR/oha-root.json" "$SLOW_TRACE" "$REQUESTS" "$THRESHOLD_US" <<'PY'
import json
import math
import re
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
trace_path = Path(sys.argv[2])
requests = int(sys.argv[3])
threshold_us = int(sys.argv[4])
raw = json.loads(json_path.read_text())
lat = raw.get("latencyPercentiles", {})
summary = raw.get("summary", {})

durations = []
bytes_values = []
if trace_path.exists():
    pattern = re.compile(r"bytes=(\d+) duration_us=(\d+)")
    for line in trace_path.read_text().splitlines():
        match = pattern.search(line)
        if match:
            bytes_values.append(int(match.group(1)))
            durations.append(int(match.group(2)))

def pct(values, percentile):
    if not values:
        return 0
    ordered = sorted(values)
    index = max(
        0,
        min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1),
    )
    return ordered[index]

count = len(durations)
print(f"trace_dir\t{trace_path.parent}")
print(f"threshold_us\t{threshold_us}")
print(f"requests\t{requests}")
print(f"oha_p50_us\t{lat.get('p50', 0) * 1_000_000:.0f}")
print(f"oha_p95_us\t{lat.get('p95', 0) * 1_000_000:.0f}")
print(f"oha_p99_us\t{lat.get('p99', 0) * 1_000_000:.0f}")
print(f"oha_p999_us\t{lat.get('p99.9', 0) * 1_000_000:.0f}")
print(f"oha_max_us\t{summary.get('slowest', 0) * 1_000_000:.0f}")
print(f"slow_write_count\t{count}")
print(f"slow_write_fraction\t{count / requests if requests else 0:.6f}")
print(f"slow_write_p50_us\t{pct(durations, 50)}")
print(f"slow_write_p95_us\t{pct(durations, 95)}")
print(f"slow_write_p99_us\t{pct(durations, 99)}")
print(f"slow_write_max_us\t{max(durations) if durations else 0}")
print(f"slow_write_median_bytes\t{pct(bytes_values, 50)}")
PY
