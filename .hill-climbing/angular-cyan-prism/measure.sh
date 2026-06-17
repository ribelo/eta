#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

if [ "${ETA_HILL_IN_NIX:-0}" != "1" ]; then
  export ETA_HILL_IN_NIX=1
  exec nix develop -c bash "$0"
fi

export EIO_BACKEND="${EIO_BACKEND:-posix}"

H2_EXE="_build/default/http-testsuite/test/server_load/h2_probe.exe"
H1_EXE="_build/default/http-testsuite/test/server_load/h1_probe.exe"
REQUESTS="${ETA_SHAPE_REQUESTS:-24000}"
REPS="${ETA_SHAPE_REPS:-9}"
TIMEOUT="${ETA_SHAPE_TIMEOUT:-5s}"
WARMUP_REQUESTS="${ETA_SHAPE_WARMUP_REQUESTS:-3000}"
TRACE_REQUESTS="${ETA_SHAPE_TRACE_REQUESTS:-4000}"
TRACE_WARMUP_REQUESTS="${ETA_SHAPE_TRACE_WARMUP_REQUESTS:-500}"

dune build --profile release \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h1_probe.exe

TMP="$(mktemp -d)"
SAMPLES="$TMP/samples.tsv"
BODY="$TMP/body-echo_1k-1024.bin"
TRACE="$TMP/h2-1x16-trace.log"
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

choose_port() {
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
}

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
  local exe="$1"
  local log="$2"
  local trace_path="${3:-}"
  PORT="$(choose_port)"
  : >"$log"
  if [ "$trace_path" = "" ]; then
    "${SERVER_CMD[@]}" "$exe" "$PORT" "$TMP" >"$log" 2>&1 &
  else
    ETA_H2_ECHO_TRACE_PATH="$trace_path" \
      "${SERVER_CMD[@]}" "$exe" "$PORT" "$TMP" >"$log" 2>&1 &
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
  local protocol="$1"
  local connections="$2"
  local streams="$3"
  local requests="$4"
  local out="$5"
  local db="$6"
  local flags=(--http-version "$protocol")

  if [ "$protocol" = "2" ]; then
    flags+=(-p "$streams")
  fi

  NO_COLOR=false "${OHA_CMD[@]}" oha --no-tui --output-format json \
    --db-url "$db" --redirect 0 --disable-compression --connect-timeout 2s \
    -t "$TIMEOUT" -c "$connections" -n "$requests" --method POST \
    -T text/plain -D "$BODY" "${flags[@]}" \
    "http://127.0.0.1:$PORT/echo" >"$out"
}

record_sample() {
  local shape="$1"
  local repeat="$2"
  local json_path="$3"
  local db_path="$4"
  local expected="$5"
  python3 - "$shape" "$repeat" "$json_path" "$db_path" "$expected" <<'PY' >>"$SAMPLES"
import json
import math
import sqlite3
import sys

shape, repeat, json_path, db_path, expected = (
    sys.argv[1],
    int(sys.argv[2]),
    sys.argv[3],
    sys.argv[4],
    int(sys.argv[5]),
)

with open(json_path, "r", encoding="utf-8") as f:
    data = json.load(f)

summary = data["summary"]
status_dist = data.get("statusCodeDistribution") or {}
error_dist = data.get("errorDistribution") or {}
total = sum(int(v) for v in status_dist.values())
errors = sum(int(v) for v in error_dist.values())

with sqlite3.connect(db_path) as con:
    rows = [
        row[0] * 1000.0
        for row in con.execute("select duration from oha order by duration")
    ]

def percentile(values, pct):
    if not values:
        return 0.0
    index = math.ceil((pct / 100.0) * len(values)) - 1
    index = max(0, min(index, len(values) - 1))
    return values[index]

ok = (
    len(rows) == expected
    and float(summary.get("successRate", 0.0)) == 1.0
    and errors == 0
    and total == expected
    and int(status_dist.get("200", 0)) == expected
)

print(
    shape,
    repeat,
    float(summary["requestsPerSec"]),
    percentile(rows, 50),
    percentile(rows, 95),
    percentile(rows, 99),
    percentile(rows, 99.5),
    rows[-1] if rows else 0.0,
    1 if ok else 0,
    sep="\t",
)
PY
}

run_shape() {
  local shape="$1"
  local exe="$2"
  local protocol="$3"
  local connections="$4"
  local streams="$5"

  start_server "$exe" "$TMP/$shape-server.log"
  run_oha "$protocol" "$connections" "$streams" "$WARMUP_REQUESTS" \
    "$TMP/$shape-warmup.json" "$TMP/$shape-warmup.db"

  for repeat in $(seq 1 "$REPS"); do
    run_oha "$protocol" "$connections" "$streams" "$REQUESTS" \
      "$TMP/$shape-$repeat.json" "$TMP/$shape-$repeat.db"
    record_sample "$shape" "$repeat" "$TMP/$shape-$repeat.json" \
      "$TMP/$shape-$repeat.db" "$REQUESTS"
  done
  stop_server
}

run_trace_shape() {
  start_server "$H2_EXE" "$TMP/h2_1x16-trace-server.log" "$TRACE"
  run_oha 2 1 16 "$TRACE_WARMUP_REQUESTS" "$TMP/h2_1x16-trace-warmup.json" \
    "$TMP/h2_1x16-trace-warmup.db"
  : >"$TRACE"
  run_oha 2 1 16 "$TRACE_REQUESTS" "$TMP/h2_1x16-trace.json" \
    "$TMP/h2_1x16-trace.db"
  stop_server
}

run_trace_shape
run_shape h2_1x16 "$H2_EXE" 2 1 16
run_shape h2_4x4 "$H2_EXE" 2 4 4
run_shape h2_16x1 "$H2_EXE" 2 16 1
run_shape h1_16 "$H1_EXE" 1.1 16 1

python3 - "$SAMPLES" "$TRACE" <<'PY'
import math
import statistics
import sys
from collections import defaultdict

samples = defaultdict(lambda: {
    "repeat": [], "rps": [], "p50": [], "p95": [], "p99": [], "p995": [],
    "max": [], "ok": []
})

samples_path, trace_path = sys.argv[1], sys.argv[2]

with open(samples_path, "r", encoding="utf-8") as f:
    for line in f:
        shape, repeat, rps, p50, p95, p99, p995, max_, ok = line.rstrip("\n").split("\t")
        current = samples[shape]
        current["repeat"].append(int(repeat))
        current["rps"].append(float(rps))
        current["p50"].append(float(p50))
        current["p95"].append(float(p95))
        current["p99"].append(float(p99))
        current["p995"].append(float(p995))
        current["max"].append(float(max_))
        current["ok"].append(int(ok))

def median(values):
    return statistics.median(values) if values else 0.0

def mad(values):
    if not values:
        return 0.0
    center = median(values)
    return median([abs(value - center) for value in values])

def metric_name(shape):
    if shape.startswith("h2_"):
        return f"h2_plain_echo_1k_{shape[3:]}"
    return f"h1_plain_echo_1k_{shape[3:]}"

shape_order = ["h2_1x16", "h2_4x4", "h2_16x1", "h1_16"]
all_ok = 1
summary = {}

for shape in shape_order:
    current = samples[shape]
    ok = 1 if current["ok"] and all(v == 1 for v in current["ok"]) else 0
    all_ok = all_ok and ok
    name = metric_name(shape)
    values = {key: median(current[key]) for key in ["rps", "p50", "p95", "p99", "p995", "max"]}
    values["p99_min"] = min(current["p99"]) if current["p99"] else 0.0
    values["p99_max"] = max(current["p99"]) if current["p99"] else 0.0
    values["p99_mad"] = mad(current["p99"])
    values["max_max"] = max(current["max"]) if current["max"] else 0.0
    summary[shape] = values
    p99_repeats = ",".join(f"{value:.3f}" for value in current["p99"])
    p995_repeats = ",".join(f"{value:.3f}" for value in current["p995"])
    max_repeats = ",".join(f"{value:.3f}" for value in current["max"])
    print(
        f"RESULT {shape} rps={values['rps']:.0f} p50_ms={values['p50']:.3f} "
        f"p95_ms={values['p95']:.3f} p99_ms={values['p99']:.3f} "
        f"p995_ms={values['p995']:.3f} max_ms={values['max']:.3f} "
        f"p99_mad_ms={values['p99_mad']:.3f} p99_repeats={p99_repeats} "
        f"p995_repeats={p995_repeats} max_repeats={max_repeats} ok={ok}"
    )
    print(f"METRIC {name}_rps={values['rps']:.0f}")
    print(f"METRIC {name}_p50_ms={values['p50']:.6f}")
    print(f"METRIC {name}_p95_ms={values['p95']:.6f}")
    print(f"METRIC {name}_p99_ms={values['p99']:.6f}")
    print(f"METRIC {name}_p995_ms={values['p995']:.6f}")
    print(f"METRIC {name}_max_ms={values['max']:.6f}")
    print(f"METRIC {name}_max_max_ms={values['max_max']:.6f}")
    print(f"METRIC {name}_p99_min_ms={values['p99_min']:.6f}")
    print(f"METRIC {name}_p99_max_ms={values['p99_max']:.6f}")
    print(f"METRIC {name}_p99_mad_ms={values['p99_mad']:.6f}")
    print(f"METRIC {name}_ok={ok}")

base = summary["h2_1x16"]["p99"]
def ratio(shape):
    return summary[shape]["p99"] / base if base > 0.0 else 0.0

print(f"METRIC h2_plain_echo_1k_4x4_vs_1x16_p99_ratio={ratio('h2_4x4'):.6f}")
print(f"METRIC h2_plain_echo_1k_16x1_vs_1x16_p99_ratio={ratio('h2_16x1'):.6f}")
print(f"METRIC h1_plain_echo_1k_16_vs_h2_1x16_p99_ratio={ratio('h1_16'):.6f}")

trace = defaultdict(list)
accepted_us_by_stream = {}
body_available_us_by_stream = {}
response_write_by_stream = {}
response_start_us_by_stream = {}
job_wait_by_stream = {}
flow_write_by_stream = {}

with open(trace_path, "r", encoding="utf-8") as f:
    for line in f:
        parts = line.strip().split()
        if not parts:
            continue
        event = parts[0]
        attrs = {}
        for item in parts[1:]:
            if "=" in item:
                key, value = item.split("=", 1)
                attrs[key] = value
        stream_id = attrs.get("stream_id")
        if event == "h2_request_accepted" and stream_id and "accepted_us" in attrs:
            accepted_us_by_stream[stream_id] = float(attrs["accepted_us"])
        elif event == "echo_handler" and stream_id:
            if "body_available_us" in attrs:
                body_available_us_by_stream[stream_id] = float(attrs["body_available_us"])
            if "request_body_read_us" in attrs:
                trace["body_read_us"].append(float(attrs["request_body_read_us"]))
        elif event == "h2_write_ready" and "wait_us" in attrs:
            trace["write_ready_wait_us"].append(float(attrs["wait_us"]))
        elif event == "h2_response_start" and stream_id and "started_us" in attrs:
            response_start_us_by_stream[stream_id] = float(attrs["started_us"])
        elif event == "h2_write_job_start" and "job_wait_us" in attrs:
            value = float(attrs["job_wait_us"])
            trace["write_job_wait_us"].append(value)
            if stream_id:
                job_wait_by_stream[stream_id] = max(job_wait_by_stream.get(stream_id, 0.0), value)
        elif event == "h2_write_flow_complete" and "flow_write_us" in attrs:
            value = float(attrs["flow_write_us"])
            trace["flow_write_us"].append(value)
            if stream_id:
                flow_write_by_stream[stream_id] = max(flow_write_by_stream.get(stream_id, 0.0), value)
        elif event == "h2_write_complete" and stream_id and "response_write_us" in attrs:
            value = float(attrs["response_write_us"])
            trace["response_write_us"].append(value)
            response_write_by_stream[stream_id] = max(response_write_by_stream.get(stream_id, 0.0), value)

accepted_to_body = [
    body_available_us_by_stream[stream_id] - accepted_us
    for stream_id, accepted_us in accepted_us_by_stream.items()
    if stream_id in body_available_us_by_stream
]
accepted_to_response_start = [
    response_start_us_by_stream[stream_id] - accepted_us
    for stream_id, accepted_us in accepted_us_by_stream.items()
    if stream_id in response_start_us_by_stream
]
accepted_to_write_complete = [
    (response_start_us_by_stream[stream_id] - accepted_us)
    + response_write_by_stream[stream_id]
    for stream_id, accepted_us in accepted_us_by_stream.items()
    if stream_id in response_start_us_by_stream
    and stream_id in response_write_by_stream
]

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

emit_dist("h2_trace_1x16_accepted_to_body_us", accepted_to_body)
emit_dist("h2_trace_1x16_accepted_to_response_start_us", accepted_to_response_start)
emit_dist("h2_trace_1x16_accepted_to_write_complete_us", accepted_to_write_complete)
emit_dist("h2_trace_1x16_body_read_us", trace["body_read_us"])
emit_dist("h2_trace_1x16_write_ready_wait_us", trace["write_ready_wait_us"])
emit_dist("h2_trace_1x16_write_job_wait_us", trace["write_job_wait_us"])
emit_dist("h2_trace_1x16_flow_write_us", trace["flow_write_us"])
emit_dist("h2_trace_1x16_response_write_us", trace["response_write_us"])

def emit_top(label, by_stream):
    top = sorted(by_stream.items(), key=lambda item: item[1], reverse=True)[:10]
    ids = [stream_id for stream_id, _ in top]
    values = [value for _, value in top]
    repeats = len(ids) - len(set(ids))
    print(
        f"RESULT h2_trace_1x16_top_{label}_streams="
        + ",".join(f"{stream_id}:{value:.0f}us" for stream_id, value in top)
    )
    print(f"METRIC h2_trace_1x16_top_{label}_unique={len(set(ids))}")
    print(f"METRIC h2_trace_1x16_top_{label}_repeated={repeats}")
    print(f"METRIC h2_trace_1x16_top_{label}_max_us={(max(values) if values else 0.0):.6f}")

emit_top("response_write", response_write_by_stream)
emit_top("job_wait", job_wait_by_stream)
emit_top("flow_write", flow_write_by_stream)

trace_success = (
    1
    if accepted_to_body
    and accepted_to_write_complete
    and trace["write_job_wait_us"]
    and trace["flow_write_us"]
    and trace["response_write_us"]
    else 0
)
print(f"METRIC h2_trace_1x16_success={trace_success}")

if all_ok and trace_success:
    print("METRIC success=1")
else:
    print("METRIC success=0")
PY
