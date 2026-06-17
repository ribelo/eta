#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_TINY_TLS_REQUESTS:-12000}"
CONNECTIONS="${ETA_TINY_TLS_CONNECTIONS:-16}"
REPEATS="${ETA_TINY_TLS_REPEATS:-1}"
THRESHOLD_US="${ETA_TINY_TLS_SLOW_THRESHOLD_US:-500}"
RUN_H2="${ETA_TINY_TLS_RUN_H2:-1}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/tiny-write-results/$STAMP"
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

cd "$ROOT"
mkdir -p "$RESULT_DIR"

nix develop -c dune build \
  http-testsuite/test/server_load/tiny_tls_probe.exe \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_tls_probe.exe

percentile_python='
import csv
import math
import re
import sys
from pathlib import Path

mode = sys.argv[1]
client_path = Path(sys.argv[2])
trace_path = Path(sys.argv[3])
threshold_us = int(sys.argv[4])
tls_io_path = Path(sys.argv[5])

totals = []
request_write = []
response_wait = []
errors = 0
with client_path.open() as f:
    reader = csv.DictReader(f, delimiter="\t")
    for row in reader:
        if row["error"]:
            errors += 1
            continue
        t0 = int(row["t0_us"])
        t1 = int(row["t1_us"])
        t2 = int(row["t2_us"])
        totals.append(t2 - t0)
        request_write.append(t1 - t0)
        response_wait.append(t2 - t1)

write_durations = []
queue_waits = []
duration_pattern = re.compile(r"duration_us=(\d+)")
queue_pattern = re.compile(r"queue_wait_us=(\d+)")
if trace_path.exists():
    for line in trace_path.read_text().splitlines():
        match = duration_pattern.search(line)
        if match:
            write_durations.append(int(match.group(1)))
        match = queue_pattern.search(line)
        if match:
            queue_waits.append(int(match.group(1)))

tls_raw_write_durations = []
tls_raw_write_bytes = []
tls_want_read = 0
tls_want_write = 0
raw_write_pattern = re.compile(r"tls_raw_write bytes=(\d+) .*write_us=(\d+)")
retry_pattern = re.compile(r"tls_ssl_write_retry .*want=([a-z_]+)")
if tls_io_path.exists():
    for line in tls_io_path.read_text().splitlines():
        match = raw_write_pattern.search(line)
        if match:
            tls_raw_write_bytes.append(int(match.group(1)))
            tls_raw_write_durations.append(int(match.group(2)))
        match = retry_pattern.search(line)
        if match:
            if match.group(1) == "read":
                tls_want_read += 1
            elif match.group(1) == "write":
                tls_want_write += 1

def pct(values, percentile):
    if not values:
        return 0
    ordered = sorted(values)
    index = max(
        0,
        min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1),
    )
    return ordered[index]

def emit(name, value):
    print(f"METRIC direct_{mode}_{name}={float(value):.6f}")

print(f"direct_mode\t{mode}")
print(f"direct_samples\t{len(totals)}")
print(f"direct_errors\t{errors}")
print(f"direct_trace\t{trace_path}")
print(
    "direct_summary\t"
    f"mode={mode}\t"
    f"total_p50_us={pct(totals, 50)}\t"
    f"total_p95_us={pct(totals, 95)}\t"
    f"total_p99_us={pct(totals, 99)}\t"
    f"response_wait_p99_us={pct(response_wait, 99)}\t"
    f"server_queue_wait_p99_us={pct(queue_waits, 99)}\t"
    f"server_write_p99_us={pct(write_durations, 99)}\t"
    f"tls_raw_write_p99_us={pct(tls_raw_write_durations, 99)}\t"
    f"tls_want_read={tls_want_read}\t"
    f"tls_want_write={tls_want_write}\t"
    f"slow_write_count={sum(1 for v in write_durations if v >= threshold_us)}"
)
emit("success", 1 if errors == 0 and len(totals) > 0 else 0)
emit("total_p50_us", pct(totals, 50))
emit("total_p95_us", pct(totals, 95))
emit("total_p99_us", pct(totals, 99))
emit("request_write_p99_us", pct(request_write, 99))
emit("response_wait_p99_us", pct(response_wait, 99))
emit("server_queue_wait_p50_us", pct(queue_waits, 50))
emit("server_queue_wait_p95_us", pct(queue_waits, 95))
emit("server_queue_wait_p99_us", pct(queue_waits, 99))
emit("server_write_p50_us", pct(write_durations, 50))
emit("server_write_p95_us", pct(write_durations, 95))
emit("server_write_p99_us", pct(write_durations, 99))
emit("tls_raw_write_p50_us", pct(tls_raw_write_durations, 50))
emit("tls_raw_write_p95_us", pct(tls_raw_write_durations, 95))
emit("tls_raw_write_p99_us", pct(tls_raw_write_durations, 99))
emit("tls_raw_write_bytes_p50", pct(tls_raw_write_bytes, 50))
emit("tls_raw_write_bytes_p99", pct(tls_raw_write_bytes, 99))
emit("tls_want_read_count", tls_want_read)
emit("tls_want_write_count", tls_want_write)
emit("slow_write_count", sum(1 for v in write_durations if v >= threshold_us))
emit(
    "slow_write_fraction",
    (sum(1 for v in write_durations if v >= threshold_us) / len(write_durations))
    if write_durations else 0,
)
'

run_direct() {
  local mode="$1"
  local label="$2"
  local split="$3"
  local mode_dir="$RESULT_DIR/direct-$label"
  local server_tmp="$TMP_DIR/server-$mode"
  local port=$((26000 + RANDOM % 12000))
  mkdir -p "$mode_dir" "$server_tmp"

  cleanup_server
  ETA_TINY_TLS_TRACE_PATH="$mode_dir/server-write.log" \
  ETA_TLS_IO_TRACE_PATH="$mode_dir/tls-io.log" \
  ETA_TINY_TLS_SPLIT_SERVER="$split" \
    taskset -c "${ETA_SERVER_LOAD_SERVER_CORE:-2}" \
    _build/default/http-testsuite/test/server_load/tiny_tls_probe.exe \
    server "$port" "$server_tmp" "$mode" \
    >"$mode_dir/server.log" 2>&1 &
  SERVER_PID="$!"

  local ready=0
  for _ in $(seq 1 200); do
    if grep -q "READY $port" "$mode_dir/server.log"; then
      ready=1
      break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$mode_dir/server.log" >&2
      exit 1
    fi
    sleep 0.05
  done
  if [[ "$ready" -ne 1 ]]; then
    cat "$mode_dir/server.log" >&2
    exit 1
  fi

  local ca_arg=()
  if [[ "$mode" == "tls" ]]; then
    ca_arg=("$server_tmp/certs/ca.pem")
  fi

  taskset -c "${ETA_SERVER_LOAD_LOAD_CORE:-3}" \
    _build/default/http-testsuite/test/server_load/tiny_tls_probe.exe \
    client 127.0.0.1 "$port" "$REQUESTS" "$CONNECTIONS" "$REPEATS" \
    "$mode_dir/client.tsv" "$mode" "${ca_arg[@]}"

  cleanup_server

  python3 -c "$percentile_python" \
    "$label" "$mode_dir/client.tsv" "$mode_dir/server-write.log" "$THRESHOLD_US" \
    "$mode_dir/tls-io.log"
}

echo "tiny_write_result_dir	$RESULT_DIR"
echo "requests	$REQUESTS"
echo "connections	$CONNECTIONS"
echo "repeats	$REPEATS"
echo "threshold_us	$THRESHOLD_US"

run_direct tls tls 0
run_direct tls tls_split 1
run_direct plain plain 0
run_direct plain plain_split 1

if [[ "$RUN_H2" != "0" ]]; then
  H2_OUT="$RESULT_DIR/h2-root-trace.tsv"
  ETA_H2_16X1_TRACE_REQUESTS="$REQUESTS" \
  ETA_H2_16X1_CONNECTIONS="$CONNECTIONS" \
  ETA_H2_16X1_STREAMS=1 \
  ETA_H2_16X1_TRACE_MODE=tls \
  ETA_TLS_IO_TRACE_PATH="$RESULT_DIR/h2-tls-io.log" \
    bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_tls.sh \
    >"$H2_OUT"
  cat "$H2_OUT"
  python3 - "$H2_OUT" "$RESULT_DIR/h2-tls-io.log" <<'PY'
import sys
import math
import re
from pathlib import Path

values = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    parts = line.split("\t")
    if len(parts) == 2:
        values[parts[0]] = parts[1]
    elif len(parts) == 7 and parts[0] == "write_complete_response_us":
        values["write_complete_response_p99_us"] = parts[4]
    elif len(parts) == 7 and parts[0] == "flow_write_us":
        values["flow_write_p99_us"] = parts[4]
    elif len(parts) == 7 and parts[0] == "write_job_wait_us":
        values["write_job_wait_p99_us"] = parts[4]

tls_path = Path(sys.argv[2])
raw_write_durations = []
raw_write_bytes = []
want_read = 0
want_write = 0
raw_write_pattern = re.compile(r"tls_raw_write bytes=(\d+) .*write_us=(\d+)")
retry_pattern = re.compile(r"tls_ssl_write_retry .*want=([a-z_]+)")
if tls_path.exists():
    for line in tls_path.read_text().splitlines():
        match = raw_write_pattern.search(line)
        if match:
            raw_write_bytes.append(int(match.group(1)))
            raw_write_durations.append(int(match.group(2)))
        match = retry_pattern.search(line)
        if match:
            if match.group(1) == "read":
                want_read += 1
            elif match.group(1) == "write":
                want_write += 1

def pct(values, percentile):
    if not values:
        return 0
    ordered = sorted(values)
    index = max(
        0,
        min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1),
    )
    return ordered[index]

values["tls_raw_write_p50_us"] = pct(raw_write_durations, 50)
values["tls_raw_write_p95_us"] = pct(raw_write_durations, 95)
values["tls_raw_write_p99_us"] = pct(raw_write_durations, 99)
values["tls_raw_write_bytes_p50"] = pct(raw_write_bytes, 50)
values["tls_raw_write_bytes_p99"] = pct(raw_write_bytes, 99)
values["tls_want_read_count"] = want_read
values["tls_want_write_count"] = want_write

for key in [
    "oha_p99_us",
    "write_complete_response_p99_us",
    "flow_write_p99_us",
    "write_job_wait_p99_us",
    "tls_raw_write_p50_us",
    "tls_raw_write_p95_us",
    "tls_raw_write_p99_us",
    "tls_raw_write_bytes_p50",
    "tls_raw_write_bytes_p99",
    "tls_want_read_count",
    "tls_want_write_count",
]:
    if key in values:
        print(f"METRIC h2_root_{key}={float(values[key]):.6f}")
PY
fi
