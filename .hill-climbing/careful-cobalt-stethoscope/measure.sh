#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

if [ "${ETA_HILL_IN_NIX:-0}" != "1" ]; then
  export ETA_HILL_IN_NIX=1
  exec nix develop -c bash "$0"
fi

export EIO_BACKEND="${EIO_BACKEND:-posix}"

EXE="_build/default/http-testsuite/test/server_load/h2_probe.exe"
CONNECTIONS="${ETA_H2PLAIN_CONNECTIONS:-1}"
STREAMS_PER_CONNECTION="${ETA_H2PLAIN_STREAMS_PER_CONNECTION:-16}"
REQUESTS="${ETA_H2PLAIN_REQUESTS:-24000}"
REPS="${ETA_H2PLAIN_REPS:-9}"
TIMEOUT="${ETA_H2PLAIN_TIMEOUT:-5s}"
WARMUP_REQUESTS="${ETA_H2PLAIN_WARMUP_REQUESTS:-3000}"
TRACE_REQUESTS="${ETA_H2PLAIN_TRACE_REQUESTS:-4000}"
TRACE_WARMUP_REQUESTS="${ETA_H2PLAIN_TRACE_WARMUP_REQUESTS:-500}"

dune build --profile release http-testsuite/test/server_load/h2_probe.exe

TMP="$(mktemp -d)"
LOG="$TMP/probe.log"
SAMPLES="$TMP/samples.tsv"
TRACE="$TMP/echo-trace.log"
BODY="$TMP/body-echo_1k-1024.bin"
touch "$SAMPLES"
python3 - "$BODY" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_bytes(b"x" * 1024)
PY

SERVER_CMD=()
OHA_CMD=()
if [ "${ETA_SERVER_LOAD_PIN:-1}" != "0" ] && command -v taskset >/dev/null 2>&1; then
  SERVER_CMD=(taskset -c "${ETA_SERVER_LOAD_SERVER_CORE:-2}")
  OHA_CMD=(taskset -c "${ETA_SERVER_LOAD_LOAD_CORE:-3}")
fi

choose_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}

PID=""
PORT=""

cleanup() {
  if [ "${PID:-}" != "" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

wait_ready() {
  local log="$1"
  for _ in $(seq 1 200); do
    grep -q READY "$log" && return 0
    sleep 0.05
  done
  echo "probe did not become ready" >&2
  cat "$log" >&2
  exit 1
}

start_server() {
  local trace_path="$1"
  local log="$2"
  PORT="$(choose_port)"
  : >"$log"
  if [ "$trace_path" = "" ]; then
    "${SERVER_CMD[@]}" "$EXE" "$PORT" "$TMP" >"$log" 2>&1 &
  else
    ETA_H2_ECHO_TRACE_PATH="$trace_path" \
      "${SERVER_CMD[@]}" "$EXE" "$PORT" "$TMP" >"$log" 2>&1 &
  fi
  PID=$!
  wait_ready "$log"
}

stop_server() {
  if [ "${PID:-}" != "" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
  fi
}

run_oha() {
  local method="$1"
  local path="$2"
  local body_path="${3:-}"
  local requests="$4"
  local out="$5"
  local flags=()

  if [ "$method" = "POST" ]; then
    flags+=(-m POST -T text/plain)
    if [ "$body_path" != "" ]; then
      flags+=(-D "$body_path")
    fi
  fi

  NO_COLOR=false "${OHA_CMD[@]}" oha --no-tui --output-format json \
    --redirect 0 --disable-compression --connect-timeout 2s -t "$TIMEOUT" \
    -c "$CONNECTIONS" -p "$STREAMS_PER_CONNECTION" -n "$requests" \
    --http-version 2 "${flags[@]}" "http://127.0.0.1:$PORT$path" >"$out"
}

record_sample() {
  local endpoint="$1"
  local out="$2"
  local expected="$3"
  python3 - "$endpoint" "$out" "$expected" <<'PY' >>"$SAMPLES"
import json
import sys

endpoint, path, expected = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

summary = data["summary"]
latency = data["latencyPercentiles"]
status_dist = data.get("statusCodeDistribution") or {}
error_dist = data.get("errorDistribution") or {}
total = sum(int(v) for v in status_dist.values())
errors = sum(int(v) for v in error_dist.values())
ok = (
    float(summary.get("successRate", 0.0)) == 1.0
    and errors == 0
    and total == expected
    and int(status_dist.get("200", 0)) == expected
)

print(
    endpoint,
    float(summary["requestsPerSec"]),
    float(latency["p50"]) * 1000.0,
    float(latency["p90"]) * 1000.0,
    float(latency["p95"]) * 1000.0,
    float(latency["p99"]) * 1000.0,
    float(summary["slowest"]) * 1000.0,
    1 if ok else 0,
    sep="\t",
)
PY
}

# Diagnostic phase. Trace is enabled only here; primary p99 below is clean.
start_server "$TRACE" "$TMP/trace-probe.log"
run_oha POST /echo "$BODY" "$TRACE_WARMUP_REQUESTS" "$TMP/trace-warmup.json"
: >"$TRACE"
run_oha POST /echo "$BODY" "$TRACE_REQUESTS" "$TMP/trace-echo.json"
record_sample trace_echo_1k "$TMP/trace-echo.json" "$TRACE_REQUESTS"
stop_server

# Primary phase. No trace env var: this is the metric hill.
start_server "" "$LOG"
run_oha POST /echo "$BODY" "$WARMUP_REQUESTS" "$TMP/warmup.json"

for repeat in $(seq 1 "$REPS"); do
  run_oha POST /echo "$BODY" "$REQUESTS" "$TMP/echo_1k-$repeat.json"
  record_sample echo_1k "$TMP/echo_1k-$repeat.json" "$REQUESTS"

  run_oha GET / "" "$REQUESTS" "$TMP/root-$repeat.json"
  record_sample root "$TMP/root-$repeat.json" "$REQUESTS"

  run_oha POST /user "" "$REQUESTS" "$TMP/post_user-$repeat.json"
  record_sample post_user "$TMP/post_user-$repeat.json" "$REQUESTS"

  run_oha GET /static/1k.bin "" "$REQUESTS" "$TMP/static_1k-$repeat.json"
  record_sample static_1k "$TMP/static_1k-$repeat.json" "$REQUESTS"
done
stop_server

python3 - "$SAMPLES" "$TRACE" <<'PY'
import math
import statistics
import sys
from collections import defaultdict

samples_path, trace_path = sys.argv[1], sys.argv[2]
samples = defaultdict(lambda: {
    "rps": [], "p50": [], "p90": [], "p95": [], "p99": [], "max": [], "ok": []
})
with open(samples_path, "r", encoding="utf-8") as f:
    for line in f:
        endpoint, rps, p50, p90, p95, p99, max_, ok = line.rstrip("\n").split("\t")
        current = samples[endpoint]
        current["rps"].append(float(rps))
        current["p50"].append(float(p50))
        current["p90"].append(float(p90))
        current["p95"].append(float(p95))
        current["p99"].append(float(p99))
        current["max"].append(float(max_))
        current["ok"].append(int(ok))

endpoints = ["echo_1k", "root", "post_user", "static_1k"]
all_ok = 1
p99_values = []
rps_values = []

def median(values):
    return statistics.median(values)

def mad(values):
    center = median(values)
    return median([abs(value - center) for value in values])

for endpoint in endpoints:
    current = samples[endpoint]
    ok = 1 if current["ok"] and all(v == 1 for v in current["ok"]) else 0
    all_ok = all_ok and ok
    rps = median(current["rps"])
    p50 = median(current["p50"])
    p90 = median(current["p90"])
    p95 = median(current["p95"])
    p99 = median(current["p99"])
    max_ = median(current["max"])
    p99_min = min(current["p99"])
    p99_max = max(current["p99"])
    p99_mad = mad(current["p99"])
    p99_values.append(p99)
    rps_values.append(rps)
    repeats = ",".join(f"{value:.3f}" for value in current["p99"])
    print(
        f"RESULT {endpoint} rps={rps:.0f} p50_ms={p50:.3f} "
        f"p95_ms={p95:.3f} p99_ms={p99:.3f} p99_mad_ms={p99_mad:.3f} "
        f"p99_repeats={repeats} ok={ok}"
    )
    print(f"METRIC h2_plain_{endpoint}_rps={rps:.0f}")
    print(f"METRIC h2_plain_{endpoint}_p50_ms={p50:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p90_ms={p90:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p95_ms={p95:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p99_ms={p99:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p99_min_ms={p99_min:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p99_max_ms={p99_max:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p99_mad_ms={p99_mad:.6f}")
    print(f"METRIC h2_plain_{endpoint}_max_ms={max_:.6f}")

trace = defaultdict(list)
trace_counts = defaultdict(int)
streams = set()
copy_bytes_total = 0
accepted_us_by_stream = {}
body_available_us_by_stream = {}
with open(trace_path, "r", encoding="utf-8") as f:
    for line in f:
        parts = line.strip().split()
        if not parts:
            continue
        event = parts[0]
        attrs = {}
        for item in parts[1:]:
            if "=" in item:
                k, v = item.split("=", 1)
                attrs[k] = v
        trace_counts[event] += 1
        if "stream_id" in attrs:
            stream_id = attrs["stream_id"]
            streams.add(stream_id)
            if event == "h2_request_accepted" and "accepted_us" in attrs:
                accepted_us_by_stream[stream_id] = float(attrs["accepted_us"])
            if event == "echo_handler" and "body_available_us" in attrs:
                body_available_us_by_stream[stream_id] = float(
                    attrs["body_available_us"]
                )
        for key in [
            "request_body_read_us",
            "handler_copy_bytes",
            "wait_us",
            "response_write_us",
            "bytes",
        ]:
            if key in attrs:
                value = float(attrs[key])
                trace[f"{event}.{key}"].append(value)
        if event in {
            "h2_request_body_copy",
            "h2_response_fixed_copy",
            "h2_write_job_copy",
        } and "bytes" in attrs:
            copy_bytes_total += float(attrs["bytes"])

def percentile(values, pct):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = math.ceil((pct / 100.0) * len(ordered)) - 1
    index = max(0, min(index, len(ordered) - 1))
    return ordered[index]

def emit_dist(metric, values):
    print(f"METRIC {metric}_count={len(values)}")
    print(f"METRIC {metric}_p50={percentile(values, 50):.6f}")
    print(f"METRIC {metric}_p95={percentile(values, 95):.6f}")
    print(f"METRIC {metric}_p99={percentile(values, 99):.6f}")

body_reads = trace["echo_handler.request_body_read_us"]
accepted_to_body = [
    body_available_us_by_stream[stream_id] - accepted_us
    for stream_id, accepted_us in accepted_us_by_stream.items()
    if stream_id in body_available_us_by_stream
]
handler_copies = trace["echo_handler.handler_copy_bytes"]
write_waits = trace["h2_write_ready.wait_us"]
write_completes = trace["h2_write_complete.response_write_us"]
request_copies = trace["h2_request_body_copy.bytes"]
response_copies = trace["h2_response_fixed_copy.bytes"]
write_job_copies = trace["h2_write_job_copy.bytes"]

emit_dist("h2_echo_trace_body_read_us", body_reads)
emit_dist("h2_echo_trace_accepted_to_body_us", accepted_to_body)
emit_dist("h2_echo_trace_write_wait_us", write_waits)
emit_dist("h2_echo_trace_response_write_us", write_completes)
emit_dist("h2_echo_trace_handler_copy_bytes", handler_copies)
emit_dist("h2_echo_trace_request_copy_bytes", request_copies)
emit_dist("h2_echo_trace_response_copy_bytes", response_copies)
emit_dist("h2_echo_trace_write_job_copy_bytes", write_job_copies)
print(f"METRIC h2_echo_trace_streams={len(streams)}")
print(f"METRIC h2_echo_trace_copy_bytes_total={copy_bytes_total:.0f}")
per_stream = copy_bytes_total / len(streams) if streams else 0.0
print(f"METRIC h2_echo_trace_copy_bytes_per_stream={per_stream:.6f}")
trace_success = (
    1 if body_reads and accepted_to_body and write_waits and write_completes else 0
)
print(f"METRIC h2_echo_trace_success={trace_success}")

trace_sample = samples["trace_echo_1k"]
trace_ok = (
    1
    if trace_sample["ok"] and all(v == 1 for v in trace_sample["ok"])
    else 0
)
print(f"METRIC h2_echo_trace_oha_success={trace_ok}")

if all_ok and all(v > 0.0 for v in p99_values + rps_values):
    p99_geomean = math.exp(sum(math.log(v) for v in p99_values) / len(p99_values))
    rps_geomean = math.exp(sum(math.log(v) for v in rps_values) / len(rps_values))
    print(f"METRIC h2_plain_p99_ms_geomean={p99_geomean:.6f}")
    print(f"METRIC h2_plain_rps_geomean={rps_geomean:.0f}")
    print("METRIC success=1")
else:
    print("METRIC h2_plain_p99_ms_geomean=0")
    print("METRIC h2_plain_rps_geomean=0")
    print("METRIC success=0")
PY
