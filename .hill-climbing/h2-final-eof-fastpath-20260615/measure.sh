#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_BODY_REQUESTS:-8000}"
CONCURRENCY="${ETA_H2_BODY_CONCURRENCY:-16}"
REPEATS="${ETA_H2_BODY_REPEATS:-5}"
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

  echo "repeat $repeat/$REPEATS: starting traced H2C probe on port $PORT" >&2
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
      sed -n '1,160p' "$SERVER_LOG" >&2
      exit 1
    fi
    sleep 0.05
  done

  if [[ "$ready" -ne 1 ]]; then
    echo "server did not become ready" >&2
    sed -n '1,160p' "$SERVER_LOG" >&2
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
result_re = re.compile(r"result=([a-z]+)")

def pct(values, p):
    if not values:
        return 0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil((p / 100.0) * len(ordered)) - 1))
    return ordered[index]

def median_metric(rows, key):
    return statistics.median(row[key] for row in rows)

def stream_entry(streams, stream_id):
    return streams.setdefault(
        stream_id,
        {
            "data_frames": [],
            "read_calls": [],
            "read_armed": [],
            "chunks": [],
            "eofs": [],
            "returns": [],
        },
    )

def parse_client(path):
    totals = {}
    with path.open(newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            stream_id = int(row["stream_id"])
            if int(row["status"]) != 200 or int(row["bytes"]) != 1024 or row["error"]:
                raise SystemExit(f"bad client row in {path}: {row}")
            totals[stream_id] = int(row["t3_us"]) - int(row["t0_us"])
    if len(totals) != requests:
        raise SystemExit(f"{path} expected {requests} streams, saw {len(totals)}")
    return totals

def parse_trace(path):
    streams = {}
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
            s = stream_entry(streams, stream_id)
            if event == "h2_request_body_data_frame":
                s["data_frames"].append(fields)
            elif event == "h2_request_body_read_call":
                s["read_calls"].append(fields["read_call_us"])
            elif event == "h2_request_body_read_armed":
                s["read_armed"].append(fields["read_armed_us"])
            elif event == "h2_request_body_chunk":
                s["chunks"].append(fields)
            elif event == "h2_request_body_eof":
                s["eofs"].append(fields)
            elif event == "h2_request_body_read_return":
                match = result_re.search(line)
                fields["result"] = match.group(1) if match else "unknown"
                fields.setdefault("final", 0)
                s["returns"].append(fields)
            elif event == "echo_handler":
                s["handler_started"] = fields["handler_started_us"]
                s["body_available"] = fields["body_available_us"]
                s["request_body_read"] = fields["request_body_read_us"]
    return streams

segment_names = [
    "handler_to_available",
    "handler_to_first_read_call",
    "first_read_call_to_arm",
    "first_arm_to_data",
    "reader_delivery_after_ready",
    "chunk_callback_to_return",
    "chunk_return_to_eof_call",
    "cached_eof_call_to_return",
    "second_read_call_to_arm",
    "eof_callback_to_return",
    "eof_return_to_body_available",
    "client_total",
]

summaries = []
all_rows = []

for repeat in range(1, repeats + 1):
    client_totals = parse_client(result_dir / f"client-{repeat}.tsv")
    trace = parse_trace(result_dir / f"server-trace-{repeat}.log")
    values = {name: [] for name in segment_names}
    final_chunks = 0
    owner_eof_reads = 0
    for stream_id in sorted(client_totals):
        s = trace.get(stream_id)
        if s is None:
            raise SystemExit(f"repeat {repeat} stream {stream_id} missing trace")
        for name in ["handler_started", "body_available", "request_body_read"]:
            if name not in s:
                raise SystemExit(f"repeat {repeat} stream {stream_id} missing {name}: {s}")
        if not s["data_frames"] or not s["read_calls"] or not s["read_armed"] or not s["chunks"]:
            raise SystemExit(f"repeat {repeat} stream {stream_id} missing body events: {s}")

        returns = sorted(s["returns"], key=lambda item: item["read_return_us"])
        chunk_returns = [item for item in returns if item["result"] == "chunk"]
        eof_returns = [item for item in returns if item["result"] == "eof"]
        if not chunk_returns or not eof_returns:
            raise SystemExit(f"repeat {repeat} stream {stream_id} missing chunk/eof returns: {s}")

        data = sorted(s["data_frames"], key=lambda item: item["data_arrived_us"])[0]
        chunk = sorted(s["chunks"], key=lambda item: item["callback_us"])[0]
        read_calls = sorted(s["read_calls"])
        read_armed = sorted(s["read_armed"])
        chunk_return = chunk_returns[0]
        eof_return = eof_returns[0]
        final_chunk = chunk_return.get("final", 0) == 1
        if final_chunk:
            final_chunks += 1
        if len(read_armed) > 1:
            owner_eof_reads += 1

        ready_for_delivery_us = max(read_armed[0], data["data_arrived_us"])
        eof_call = read_calls[1] if len(read_calls) > 1 else chunk_return["read_return_us"]
        cached_eof_call_to_return = eof_return["read_return_us"] - eof_call if final_chunk else 0
        second_read_call_to_arm = (
            read_armed[1] - eof_call if len(read_armed) > 1 else 0
        )
        eof_callback_to_return = 0
        if s["eofs"]:
            eof = sorted(s["eofs"], key=lambda item: item["eof_us"])[0]
            eof_callback_to_return = eof_return["read_return_us"] - eof["eof_us"]

        row = {
            "repeat": repeat,
            "stream_id": stream_id,
            "handler_to_available": s["body_available"] - s["handler_started"],
            "handler_to_first_read_call": read_calls[0] - s["handler_started"],
            "first_read_call_to_arm": read_armed[0] - read_calls[0],
            "first_arm_to_data": data["data_arrived_us"] - read_armed[0],
            "reader_delivery_after_ready": chunk["callback_us"] - ready_for_delivery_us,
            "chunk_callback_to_return": chunk_return["read_return_us"] - chunk["callback_us"],
            "chunk_return_to_eof_call": eof_call - chunk_return["read_return_us"],
            "cached_eof_call_to_return": cached_eof_call_to_return,
            "second_read_call_to_arm": second_read_call_to_arm,
            "eof_callback_to_return": eof_callback_to_return,
            "eof_return_to_body_available": s["body_available"] - eof_return["read_return_us"],
            "client_total": client_totals[stream_id],
        }
        for name in segment_names:
            values[name].append(row[name])
        all_rows.append(row)

    summary = {"repeat": repeat}
    for name in segment_names:
        summary[f"{name}_p50_us"] = pct(values[name], 50)
        summary[f"{name}_p95_us"] = pct(values[name], 95)
        summary[f"{name}_p99_us"] = pct(values[name], 99)
        summary[f"{name}_p995_us"] = pct(values[name], 99.5)
        summary[f"{name}_max_us"] = max(values[name]) if values[name] else 0
    summary["final_chunk_fraction"] = final_chunks / requests
    summary["owner_eof_read_fraction"] = owner_eof_reads / requests
    summaries.append(summary)

summary_path = result_dir / "fastpath-summary.tsv"
fields = (
    ["repeat", "final_chunk_fraction", "owner_eof_read_fraction"]
    + [f"{name}_p99_us" for name in segment_names]
)
with summary_path.open("w", newline="") as f:
    writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields)
    writer.writeheader()
    for summary in summaries:
        writer.writerow({field: summary[field] for field in fields})

samples_path = result_dir / "fastpath-samples.tsv"
with samples_path.open("w", newline="") as f:
    fields = ["repeat", "stream_id"] + segment_names
    writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields)
    writer.writeheader()
    for row in all_rows:
        writer.writerow({field: row[field] for field in fields})

print(
    "repeat\thandler_p99_us\tclient_p99_us\tfinal_fraction\towner_eof_fraction\t"
    "first_cmd_p99_us\tchunk_return_p99_us\tcached_eof_return_p99_us\t"
    "second_cmd_p99_us\teof_return_p99_us\tpost_eof_p99_us"
)
for summary in summaries:
    print(
        f"{summary['repeat']}\t"
        f"{summary['handler_to_available_p99_us']}\t"
        f"{summary['client_total_p99_us']}\t"
        f"{summary['final_chunk_fraction']:.6f}\t"
        f"{summary['owner_eof_read_fraction']:.6f}\t"
        f"{summary['first_read_call_to_arm_p99_us']}\t"
        f"{summary['chunk_callback_to_return_p99_us']}\t"
        f"{summary['cached_eof_call_to_return_p99_us']}\t"
        f"{summary['second_read_call_to_arm_p99_us']}\t"
        f"{summary['eof_callback_to_return_p99_us']}\t"
        f"{summary['eof_return_to_body_available_p99_us']}"
    )

top_text = ",".join(
    f"r{row['repeat']}:s{row['stream_id']}:body={row['handler_to_available']}us"
    f"/client={row['client_total']}us"
    f"/cmd={row['first_read_call_to_arm']}us"
    f"/chunk_return={row['chunk_callback_to_return']}us"
    f"/cached_eof={row['cached_eof_call_to_return']}us"
    f"/second_cmd={row['second_read_call_to_arm']}us"
    f"/eof_return={row['eof_callback_to_return']}us"
    f"/post={row['eof_return_to_body_available']}us"
    for row in sorted(all_rows, key=lambda row: row["handler_to_available"], reverse=True)[:10]
)
print(f"RESULT top_handler_to_available={top_text}")

metrics = {
    "h2_body_handler_to_available_p99_us": median_metric(summaries, "handler_to_available_p99_us"),
    "h2_body_handler_to_available_p995_us": median_metric(summaries, "handler_to_available_p995_us"),
    "h2_body_handler_to_available_max_us": max(summary["handler_to_available_max_us"] for summary in summaries),
    "h2_client_total_p99_us": median_metric(summaries, "client_total_p99_us"),
    "h2_client_total_p995_us": median_metric(summaries, "client_total_p995_us"),
    "h2_body_final_chunk_fraction": median_metric(summaries, "final_chunk_fraction"),
    "h2_body_owner_eof_read_fraction": median_metric(summaries, "owner_eof_read_fraction"),
    "h2_body_first_read_call_to_arm_p99_us": median_metric(summaries, "first_read_call_to_arm_p99_us"),
    "h2_body_first_arm_to_data_p99_us": median_metric(summaries, "first_arm_to_data_p99_us"),
    "h2_body_reader_delivery_after_ready_p99_us": median_metric(summaries, "reader_delivery_after_ready_p99_us"),
    "h2_body_chunk_callback_to_return_p99_us": median_metric(summaries, "chunk_callback_to_return_p99_us"),
    "h2_body_chunk_return_to_eof_call_p99_us": median_metric(summaries, "chunk_return_to_eof_call_p99_us"),
    "h2_body_cached_eof_call_to_return_p99_us": median_metric(summaries, "cached_eof_call_to_return_p99_us"),
    "h2_body_second_read_call_to_arm_p99_us": median_metric(summaries, "second_read_call_to_arm_p99_us"),
    "h2_body_eof_callback_to_return_p99_us": median_metric(summaries, "eof_callback_to_return_p99_us"),
    "h2_body_eof_return_to_available_p99_us": median_metric(summaries, "eof_return_to_body_available_p99_us"),
    "h2_body_success": 1.0,
}
for name, value in metrics.items():
    print(f"METRIC {name}={value:.6f}")
print(f"fastpath samples: {samples_path}", file=sys.stderr)
print(f"fastpath summary: {summary_path}", file=sys.stderr)
PY
