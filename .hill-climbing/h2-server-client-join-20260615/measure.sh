#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_JOIN_REQUESTS:-8000}"
CONCURRENCY="${ETA_H2_JOIN_CONCURRENCY:-16}"
REPEATS="${ETA_H2_JOIN_REPEATS:-5}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/results/$STAMP"
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

echo "building h2 probe and checkpoint client" >&2
nix develop -c dune build \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

for repeat in $(seq 1 "$REPEATS"); do
  PORT=$((18000 + RANDOM % 20000))
  SERVER_TMP="$TMP_DIR/server-$repeat"
  SERVER_LOG="$RESULT_DIR/server-$repeat.log"
  TRACE="$RESULT_DIR/server-trace-$repeat.log"
  CLIENT_TSV="$RESULT_DIR/client-$repeat.tsv"
  mkdir -p "$SERVER_TMP"

  echo "repeat $repeat/$REPEATS: starting H2C probe on port $PORT" >&2
  ETA_H2_ECHO_TRACE_PATH="$TRACE" \
    _build/default/http-testsuite/test/server_load/h2_probe.exe \
    "$PORT" "$SERVER_TMP" >"$SERVER_LOG" 2>&1 &
  SERVER_PID="$!"

  ready=0
  for _ in $(seq 1 200); do
    if grep -q "READY $PORT" "$SERVER_LOG"; then
      ready=1
      break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "server exited before ready" >&2
      cat "$SERVER_LOG" >&2
      exit 1
    fi
    sleep 0.05
  done

  if [[ "$ready" -ne 1 ]]; then
    echo "server did not become ready" >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi

  _build/default/http-testsuite/test/server_load/h2_gap_client.exe \
    127.0.0.1 "$PORT" "$REQUESTS" "$CONCURRENCY" 1 "$CLIENT_TSV"
  cleanup_server
done

python - "$RESULT_DIR" "$REQUESTS" "$REPEATS" <<'PY'
import csv
import math
import re
import statistics
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
requests = int(sys.argv[2])
repeats = int(sys.argv[3])

kv_re = re.compile(r"([a-zA-Z_]+)=(-?\d+)")

def pct(values, p):
    if not values:
        raise SystemExit(f"no values for p{p}")
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil((p / 100.0) * len(ordered)) - 1))
    return ordered[index]

def median_metric(rows, key):
    return statistics.median(row[key] for row in rows)

def parse_client(path):
    out = {}
    with path.open(newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            status = int(row["status"])
            echoed = int(row["bytes"])
            error = row["error"]
            if status != 200 or echoed != 1024 or error:
                raise SystemExit(f"bad client row in {path}: {row}")
            stream_id = int(row["stream_id"])
            values = {
                "t0": int(row["t0_us"]),
                "t1": int(row["t1_us"]),
                "t2": int(row["t2_us"]),
                "t3": int(row["t3_us"]),
                "rx_headers": int(row["rx_headers_us"]),
                "rx_body_end": int(row["rx_body_end_us"]),
            }
            if min(values.values()) < 0:
                raise SystemExit(f"missing client timestamp in {path}: {row}")
            out[stream_id] = values
    if len(out) != requests:
        raise SystemExit(f"{path} expected {requests} streams, saw {len(out)}")
    return out

def parse_trace(path):
    streams = {}
    def stream(stream_id):
        return streams.setdefault(stream_id, {})
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            event = line.split(" ", 1)[0]
            fields = {name: int(value) for name, value in kv_re.findall(line)}
            stream_id = fields.get("stream_id")
            if stream_id is None:
                continue
            s = stream(stream_id)
            if event == "h2_request_accepted":
                s["accepted"] = fields["accepted_us"]
            elif event == "echo_handler":
                s["handler_started"] = fields["handler_started_us"]
                s["body_available"] = fields["body_available_us"]
                s["request_body_read"] = fields["request_body_read_us"]
            elif event == "h2_response_start":
                s["response_start"] = fields["started_us"]
                s["response_bytes"] = fields["response_bytes"]
            elif event == "h2_write_ready":
                s.setdefault("write_ready_wait", fields["wait_us"])
            elif event == "h2_write_job_start":
                s.setdefault("write_job_wait", fields["job_wait_us"])
            elif event == "h2_write_flow_complete":
                s.setdefault("flow_write", fields["flow_write_us"])
            elif event == "h2_write_complete":
                s.setdefault("owner_response_write", fields["response_write_us"])
    for stream_id, s in streams.items():
        if "response_start" in s and "write_ready_wait" in s and "write_job_wait" in s and "flow_write" in s:
            s["flow_complete"] = (
                s["response_start"]
                + s["write_ready_wait"]
                + s["write_job_wait"]
                + s["flow_write"]
            )
        if "response_start" in s and "owner_response_write" in s:
            s["owner_write_complete"] = s["response_start"] + s["owner_response_write"]
    return streams

segment_names = [
    "client_t1_to_rx_headers",
    "client_t1_to_server_accepted",
    "server_accepted_to_handler_started",
    "server_handler_started_to_body_available",
    "server_accepted_to_body_available",
    "server_body_available_to_response_start",
    "server_accepted_to_response_start",
    "server_response_start_to_write_ready",
    "server_write_ready_to_job_start",
    "server_job_start_to_flow_complete",
    "server_accepted_to_flow_complete",
    "server_flow_complete_to_rx_headers",
    "server_owner_write_complete_to_rx_headers",
    "client_rx_headers_to_t2",
    "client_t2_to_t3",
]

summaries = []
all_rows = []
top_rows = []
tail_rows_by_repeat = []

for repeat in range(1, repeats + 1):
    client = parse_client(result_dir / f"client-{repeat}.tsv")
    trace = parse_trace(result_dir / f"server-trace-{repeat}.log")
    values = {name: [] for name in segment_names}
    joined = 0
    for stream_id, c in client.items():
        s = trace.get(stream_id)
        required = [
            "accepted",
            "handler_started",
            "body_available",
            "response_start",
            "flow_complete",
            "owner_write_complete",
        ]
        if s is None or any(name not in s for name in required):
            raise SystemExit(f"repeat {repeat} stream {stream_id} missing server trace: {s}")
        joined += 1
        row = {
            "repeat": repeat,
            "stream_id": stream_id,
            "client_t1_to_rx_headers": c["rx_headers"] - c["t1"],
            "client_t1_to_server_accepted": s["accepted"] - c["t1"],
            "server_accepted_to_handler_started": s["handler_started"] - s["accepted"],
            "server_handler_started_to_body_available": s["body_available"] - s["handler_started"],
            "server_accepted_to_body_available": s["body_available"] - s["accepted"],
            "server_body_available_to_response_start": s["response_start"] - s["body_available"],
            "server_accepted_to_response_start": s["response_start"] - s["accepted"],
            "server_response_start_to_write_ready": s["write_ready_wait"],
            "server_write_ready_to_job_start": s["write_job_wait"],
            "server_job_start_to_flow_complete": s["flow_write"],
            "server_accepted_to_flow_complete": s["flow_complete"] - s["accepted"],
            "server_flow_complete_to_rx_headers": c["rx_headers"] - s["flow_complete"],
            "server_owner_write_complete_to_rx_headers": c["rx_headers"] - s["owner_write_complete"],
            "client_rx_headers_to_t2": c["t2"] - c["rx_headers"],
            "client_t2_to_t3": c["t3"] - c["t2"],
        }
        for name in segment_names:
            values[name].append(row[name])
        all_rows.append(row)
    if joined != requests:
        raise SystemExit(f"repeat {repeat} expected {requests} joins, saw {joined}")
    summary = {"repeat": repeat}
    repeat_rows = [row for row in all_rows if row["repeat"] == repeat]
    tail_n = max(1, math.ceil(len(repeat_rows) * 0.01))
    tail_rows = sorted(repeat_rows, key=lambda row: row["client_t1_to_rx_headers"], reverse=True)[:tail_n]
    dominant = {
        "pre_accept": 0,
        "accepted_to_flow": 0,
        "flow_to_rx": 0,
        "rx_to_t2": 0,
    }
    for row in tail_rows:
        parts = {
            "pre_accept": max(0, row["client_t1_to_server_accepted"]),
            "accepted_to_flow": max(0, row["server_accepted_to_flow_complete"]),
            "flow_to_rx": max(0, row["server_flow_complete_to_rx_headers"]),
            "rx_to_t2": max(0, row["client_rx_headers_to_t2"]),
        }
        dominant[max(parts, key=parts.get)] += 1
    summary["tail1pct_pre_accept_fraction"] = dominant["pre_accept"] / tail_n
    summary["tail1pct_accepted_to_flow_fraction"] = dominant["accepted_to_flow"] / tail_n
    summary["tail1pct_flow_to_rx_fraction"] = dominant["flow_to_rx"] / tail_n
    summary["tail1pct_rx_to_t2_fraction"] = dominant["rx_to_t2"] / tail_n
    summary["tail1pct_pre_accept_median_us"] = statistics.median(row["client_t1_to_server_accepted"] for row in tail_rows)
    summary["tail1pct_accepted_to_flow_median_us"] = statistics.median(row["server_accepted_to_flow_complete"] for row in tail_rows)
    summary["tail1pct_flow_to_rx_median_us"] = statistics.median(row["server_flow_complete_to_rx_headers"] for row in tail_rows)
    summary["tail1pct_rx_to_t2_median_us"] = statistics.median(row["client_rx_headers_to_t2"] for row in tail_rows)
    flow_tail_rows = sorted(repeat_rows, key=lambda row: row["server_accepted_to_flow_complete"], reverse=True)[:tail_n]
    flow_dominant = {
        "handler_start": 0,
        "body_read": 0,
        "response_start": 0,
        "write_ready": 0,
        "job_wait": 0,
        "flow_write": 0,
    }
    for row in flow_tail_rows:
        parts = {
            "handler_start": max(0, row["server_accepted_to_handler_started"]),
            "body_read": max(0, row["server_handler_started_to_body_available"]),
            "response_start": max(0, row["server_body_available_to_response_start"]),
            "write_ready": max(0, row["server_response_start_to_write_ready"]),
            "job_wait": max(0, row["server_write_ready_to_job_start"]),
            "flow_write": max(0, row["server_job_start_to_flow_complete"]),
        }
        flow_dominant[max(parts, key=parts.get)] += 1
    summary["flow_tail1pct_handler_start_fraction"] = flow_dominant["handler_start"] / tail_n
    summary["flow_tail1pct_body_read_fraction"] = flow_dominant["body_read"] / tail_n
    summary["flow_tail1pct_response_start_fraction"] = flow_dominant["response_start"] / tail_n
    summary["flow_tail1pct_write_ready_fraction"] = flow_dominant["write_ready"] / tail_n
    summary["flow_tail1pct_job_wait_fraction"] = flow_dominant["job_wait"] / tail_n
    summary["flow_tail1pct_flow_write_fraction"] = flow_dominant["flow_write"] / tail_n
    summary["flow_tail1pct_handler_start_median_us"] = statistics.median(row["server_accepted_to_handler_started"] for row in flow_tail_rows)
    summary["flow_tail1pct_body_read_median_us"] = statistics.median(row["server_handler_started_to_body_available"] for row in flow_tail_rows)
    summary["flow_tail1pct_response_start_median_us"] = statistics.median(row["server_body_available_to_response_start"] for row in flow_tail_rows)
    summary["flow_tail1pct_write_ready_median_us"] = statistics.median(row["server_response_start_to_write_ready"] for row in flow_tail_rows)
    summary["flow_tail1pct_job_wait_median_us"] = statistics.median(row["server_write_ready_to_job_start"] for row in flow_tail_rows)
    summary["flow_tail1pct_flow_write_median_us"] = statistics.median(row["server_job_start_to_flow_complete"] for row in flow_tail_rows)
    tail_rows_by_repeat.extend(tail_rows)
    for name in segment_names:
        summary[f"{name}_p50_us"] = pct(values[name], 50)
        summary[f"{name}_p95_us"] = pct(values[name], 95)
        summary[f"{name}_p99_us"] = pct(values[name], 99)
        summary[f"{name}_p995_us"] = pct(values[name], 99.5)
        summary[f"{name}_max_us"] = max(values[name])
    summaries.append(summary)
    top_rows.extend(sorted((row for row in all_rows if row["repeat"] == repeat), key=lambda row: row["client_t1_to_rx_headers"], reverse=True)[:5])

summary_path = result_dir / "joined-summary.tsv"
fields = ["repeat"] + [f"{name}_p99_us" for name in segment_names]
with summary_path.open("w", newline="") as f:
    writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields)
    writer.writeheader()
    for summary in summaries:
        writer.writerow({field: summary[field] for field in fields})

joined_path = result_dir / "joined-samples.tsv"
with joined_path.open("w", newline="") as f:
    fields = ["repeat", "stream_id"] + segment_names
    writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields)
    writer.writeheader()
    for row in all_rows:
        writer.writerow({field: row[field] for field in fields})

print("repeat\tclient_t1_rx_headers_p99_us\tt1_accepted_p99_us\taccepted_flow_done_p99_us\taccepted_handler_p99_us\thandler_body_p99_us\tbody_avail_p99_us\tbody_to_resp_p99_us\tresp_to_ready_p99_us\tjob_wait_p99_us\tflow_write_p99_us\tflow_done_rx_headers_p99_us\trx_headers_t2_p99_us")
for summary in summaries:
    print(
        f"{summary['repeat']}\t"
        f"{summary['client_t1_to_rx_headers_p99_us']}\t"
        f"{summary['client_t1_to_server_accepted_p99_us']}\t"
        f"{summary['server_accepted_to_flow_complete_p99_us']}\t"
        f"{summary['server_accepted_to_handler_started_p99_us']}\t"
        f"{summary['server_handler_started_to_body_available_p99_us']}\t"
        f"{summary['server_accepted_to_body_available_p99_us']}\t"
        f"{summary['server_body_available_to_response_start_p99_us']}\t"
        f"{summary['server_response_start_to_write_ready_p99_us']}\t"
        f"{summary['server_write_ready_to_job_start_p99_us']}\t"
        f"{summary['server_job_start_to_flow_complete_p99_us']}\t"
        f"{summary['server_flow_complete_to_rx_headers_p99_us']}\t"
        f"{summary['client_rx_headers_to_t2_p99_us']}"
    )

top_text = ",".join(
    f"r{row['repeat']}:s{row['stream_id']}:total={row['client_t1_to_rx_headers']}us"
    f"/t1_accept={row['client_t1_to_server_accepted']}us"
    f"/accept_flow={row['server_accepted_to_flow_complete']}us"
    f"/flow_rx={row['server_flow_complete_to_rx_headers']}us"
    for row in sorted(top_rows, key=lambda row: row["client_t1_to_rx_headers"], reverse=True)[:10]
)
print(f"RESULT top_client_t1_to_rx_headers={top_text}")
tail_text = ",".join(
    f"r{row['repeat']}:s{row['stream_id']}:total={row['client_t1_to_rx_headers']}us"
    f"/pre_accept={row['client_t1_to_server_accepted']}us"
    f"/accept_flow={row['server_accepted_to_flow_complete']}us"
    f"/flow_rx={row['server_flow_complete_to_rx_headers']}us"
    f"/rx_t2={row['client_rx_headers_to_t2']}us"
    for row in sorted(tail_rows_by_repeat, key=lambda row: row["client_t1_to_rx_headers"], reverse=True)[:10]
)
print(f"RESULT tail1pct_top_breakdown={tail_text}")
flow_tail_text = ",".join(
    f"r{row['repeat']}:s{row['stream_id']}:accepted_flow={row['server_accepted_to_flow_complete']}us"
    f"/accept_handler={row['server_accepted_to_handler_started']}us"
    f"/handler_body={row['server_handler_started_to_body_available']}us"
    f"/body_resp={row['server_body_available_to_response_start']}us"
    f"/resp_ready={row['server_response_start_to_write_ready']}us"
    f"/job_wait={row['server_write_ready_to_job_start']}us"
    f"/flow_write={row['server_job_start_to_flow_complete']}us"
    for row in sorted(all_rows, key=lambda row: row["server_accepted_to_flow_complete"], reverse=True)[:10]
)
print(f"RESULT top_server_accepted_to_flow={flow_tail_text}")

metrics = {
    "h2c_join_t1_to_rx_headers_p99_us": median_metric(summaries, "client_t1_to_rx_headers_p99_us"),
    "h2c_join_t1_to_rx_headers_p995_us": median_metric(summaries, "client_t1_to_rx_headers_p995_us"),
    "h2c_join_t1_to_rx_headers_max_us": max(summary["client_t1_to_rx_headers_max_us"] for summary in summaries),
    "h2c_join_t1_to_accepted_p99_us": median_metric(summaries, "client_t1_to_server_accepted_p99_us"),
    "h2c_join_accepted_to_handler_started_p99_us": median_metric(summaries, "server_accepted_to_handler_started_p99_us"),
    "h2c_join_handler_started_to_body_available_p99_us": median_metric(summaries, "server_handler_started_to_body_available_p99_us"),
    "h2c_join_accepted_to_body_available_p99_us": median_metric(summaries, "server_accepted_to_body_available_p99_us"),
    "h2c_join_body_available_to_response_start_p99_us": median_metric(summaries, "server_body_available_to_response_start_p99_us"),
    "h2c_join_accepted_to_response_start_p99_us": median_metric(summaries, "server_accepted_to_response_start_p99_us"),
    "h2c_join_response_start_to_write_ready_p99_us": median_metric(summaries, "server_response_start_to_write_ready_p99_us"),
    "h2c_join_write_ready_to_job_start_p99_us": median_metric(summaries, "server_write_ready_to_job_start_p99_us"),
    "h2c_join_job_start_to_flow_complete_p99_us": median_metric(summaries, "server_job_start_to_flow_complete_p99_us"),
    "h2c_join_accepted_to_flow_complete_p99_us": median_metric(summaries, "server_accepted_to_flow_complete_p99_us"),
    "h2c_join_write_complete_to_rx_headers_p99_us": median_metric(summaries, "server_flow_complete_to_rx_headers_p99_us"),
    "h2c_join_write_complete_to_rx_headers_p995_us": median_metric(summaries, "server_flow_complete_to_rx_headers_p995_us"),
    "h2c_join_write_complete_to_rx_headers_max_us": max(summary["server_flow_complete_to_rx_headers_max_us"] for summary in summaries),
    "h2c_join_owner_write_complete_to_rx_headers_p99_us": median_metric(summaries, "server_owner_write_complete_to_rx_headers_p99_us"),
    "h2c_join_rx_headers_to_t2_p99_us": median_metric(summaries, "client_rx_headers_to_t2_p99_us"),
    "h2c_join_t2_to_t3_p99_us": median_metric(summaries, "client_t2_to_t3_p99_us"),
    "h2c_join_tail1pct_dominant_pre_accept_fraction": median_metric(summaries, "tail1pct_pre_accept_fraction"),
    "h2c_join_tail1pct_dominant_accepted_to_flow_fraction": median_metric(summaries, "tail1pct_accepted_to_flow_fraction"),
    "h2c_join_tail1pct_dominant_flow_to_rx_fraction": median_metric(summaries, "tail1pct_flow_to_rx_fraction"),
    "h2c_join_tail1pct_dominant_rx_to_t2_fraction": median_metric(summaries, "tail1pct_rx_to_t2_fraction"),
    "h2c_join_tail1pct_pre_accept_median_us": median_metric(summaries, "tail1pct_pre_accept_median_us"),
    "h2c_join_tail1pct_accepted_to_flow_median_us": median_metric(summaries, "tail1pct_accepted_to_flow_median_us"),
    "h2c_join_tail1pct_flow_to_rx_median_us": median_metric(summaries, "tail1pct_flow_to_rx_median_us"),
    "h2c_join_tail1pct_rx_to_t2_median_us": median_metric(summaries, "tail1pct_rx_to_t2_median_us"),
    "h2c_join_flow_tail1pct_dominant_handler_start_fraction": median_metric(summaries, "flow_tail1pct_handler_start_fraction"),
    "h2c_join_flow_tail1pct_dominant_body_read_fraction": median_metric(summaries, "flow_tail1pct_body_read_fraction"),
    "h2c_join_flow_tail1pct_dominant_response_start_fraction": median_metric(summaries, "flow_tail1pct_response_start_fraction"),
    "h2c_join_flow_tail1pct_dominant_write_ready_fraction": median_metric(summaries, "flow_tail1pct_write_ready_fraction"),
    "h2c_join_flow_tail1pct_dominant_job_wait_fraction": median_metric(summaries, "flow_tail1pct_job_wait_fraction"),
    "h2c_join_flow_tail1pct_dominant_flow_write_fraction": median_metric(summaries, "flow_tail1pct_flow_write_fraction"),
    "h2c_join_flow_tail1pct_handler_start_median_us": median_metric(summaries, "flow_tail1pct_handler_start_median_us"),
    "h2c_join_flow_tail1pct_body_read_median_us": median_metric(summaries, "flow_tail1pct_body_read_median_us"),
    "h2c_join_flow_tail1pct_response_start_median_us": median_metric(summaries, "flow_tail1pct_response_start_median_us"),
    "h2c_join_flow_tail1pct_write_ready_median_us": median_metric(summaries, "flow_tail1pct_write_ready_median_us"),
    "h2c_join_flow_tail1pct_job_wait_median_us": median_metric(summaries, "flow_tail1pct_job_wait_median_us"),
    "h2c_join_flow_tail1pct_flow_write_median_us": median_metric(summaries, "flow_tail1pct_flow_write_median_us"),
    "h2c_join_success": 1.0,
}
for name, value in metrics.items():
    print(f"METRIC {name}={value:.6f}")
print(f"joined samples: {joined_path}", file=sys.stderr)
print(f"joined summary: {summary_path}", file=sys.stderr)
PY
