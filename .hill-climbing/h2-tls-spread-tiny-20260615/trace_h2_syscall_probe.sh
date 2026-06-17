#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_SYSCALL_REQUESTS:-1000}"
CONNECTIONS="${ETA_H2_SYSCALL_CONNECTIONS:-16}"
STREAMS="${ETA_H2_SYSCALL_STREAMS:-1}"
TIMEOUT="${ETA_H2_SYSCALL_TIMEOUT:-5s}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/syscall-probe-results/$STAMP"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -- "-$SERVER_PID" 2>/dev/null || kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT"
mkdir -p "$RESULT_DIR" "$TMP_DIR/server"

nix develop -c dune build http-testsuite/test/server_load/h2_tls_probe.exe

PORT=$((27000 + RANDOM % 10000))
SERVER_LOG="$RESULT_DIR/server.log"
SERVER_H2_TRACE="$RESULT_DIR/server-h2.log"
STRACE_PREFIX="$RESULT_DIR/strace"

ETA_H2_ECHO_TRACE_PATH="$SERVER_H2_TRACE" \
  setsid strace -ff -ttt -T \
  -e trace=io_uring_enter,write,writev,sendto,sendmsg \
  -o "$STRACE_PREFIX" \
  taskset -c "${ETA_SERVER_LOAD_SERVER_CORE:-2}" \
  _build/default/http-testsuite/test/server_load/h2_tls_probe.exe \
  "$PORT" "$TMP_DIR/server" >"$SERVER_LOG" 2>"$RESULT_DIR/server.err" &
SERVER_PID="$!"

ready=0
for _ in $(seq 1 200); do
  if grep -q "READY $PORT" "$SERVER_LOG"; then
    ready=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$SERVER_LOG" >&2
    cat "$RESULT_DIR/server.err" >&2
    exit 1
  fi
  sleep 0.05
done

if [[ "$ready" -ne 1 ]]; then
  cat "$SERVER_LOG" >&2
  cat "$RESULT_DIR/server.err" >&2
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
  --insecure \
  "https://127.0.0.1:$PORT/" \
  >"$RESULT_DIR/oha-root.json" 2>"$RESULT_DIR/oha-root.err"

kill -- "-$SERVER_PID" 2>/dev/null || kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

python3 - "$RESULT_DIR/oha-root.json" "$SERVER_H2_TRACE" "$RESULT_DIR" "$REQUESTS" <<'PY'
import json
import math
import re
import sys
from pathlib import Path

json_path = Path(sys.argv[1])
trace_path = Path(sys.argv[2])
result_dir = Path(sys.argv[3])
expected_requests = int(sys.argv[4])

raw = json.loads(json_path.read_text())
lat = raw.get("latencyPercentiles", {})
summary = raw.get("summary", {})

patterns = {
    "write_complete_response_us": re.compile(
        r"h2_write_complete .*response_write_us=(\d+)"
    ),
    "write_job_wait_us": re.compile(r"h2_write_job_start .*job_wait_us=(\d+)"),
    "flow_write_us": re.compile(r"h2_write_flow_complete .*flow_write_us=(\d+)"),
    "ingress_plain_wait_us": re.compile(r"h2_ingress_plain_read .*wait_us=(\d+)"),
}
values = {name: [] for name in patterns}
if trace_path.exists():
    for line in trace_path.read_text().splitlines():
        for name, pattern in patterns.items():
            match = pattern.search(line)
            if match:
                values[name].append(int(match.group(1)))

syscall_durations = {
    "io_uring_enter": [],
    "write": [],
    "writev": [],
    "sendto": [],
    "sendmsg": [],
}
duration_pattern = re.compile(r"<(\d+\.\d+)>")
name_pattern = re.compile(r"(io_uring_enter|writev?|sendto|sendmsg)\(")
for path in result_dir.glob("strace.*"):
    for line in path.read_text(errors="replace").splitlines():
        name_match = name_pattern.search(line)
        duration_match = duration_pattern.search(line)
        if not name_match or not duration_match:
            continue
        syscall_durations[name_match.group(1)].append(
            int(float(duration_match.group(1)) * 1_000_000)
        )

def pct(samples, percentile):
    if not samples:
        return 0
    ordered = sorted(samples)
    index = max(
        0,
        min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1),
    )
    return ordered[index]

def emit(name, value):
    print(f"METRIC {name}={float(value):.6f}")

print(f"syscall_probe_result_dir\t{result_dir}")
print(f"syscall_probe_expected_requests\t{expected_requests}")
print(f"oha_p50_us\t{lat.get('p50', 0) * 1_000_000:.0f}")
print(f"oha_p95_us\t{lat.get('p95', 0) * 1_000_000:.0f}")
print(f"oha_p99_us\t{lat.get('p99', 0) * 1_000_000:.0f}")
print(f"oha_max_us\t{summary.get('slowest', 0) * 1_000_000:.0f}")

print("metric\tn\tp50_us\tp95_us\tp99_us\tmax_us")
for name, samples in values.items():
    print(
        f"{name}\t{len(samples)}\t{pct(samples, 50)}\t{pct(samples, 95)}\t"
        f"{pct(samples, 99)}\t{max(samples) if samples else 0}"
    )
for name, samples in syscall_durations.items():
    print(
        f"syscall_{name}_us\t{len(samples)}\t{pct(samples, 50)}\t"
        f"{pct(samples, 95)}\t{pct(samples, 99)}\t"
        f"{max(samples) if samples else 0}"
    )

emit("h2_syscall_probe_success", 1)
emit("h2_syscall_oha_p99_us", lat.get("p99", 0) * 1_000_000)
emit("h2_syscall_flow_write_p99_us", pct(values["flow_write_us"], 99))
emit(
    "h2_syscall_write_complete_response_p99_us",
    pct(values["write_complete_response_us"], 99),
)
emit("h2_syscall_write_job_wait_p99_us", pct(values["write_job_wait_us"], 99))
for name, samples in syscall_durations.items():
    emit(f"h2_syscall_{name}_p99_us", pct(samples, 99))
    emit(f"h2_syscall_{name}_count", len(samples))
PY
