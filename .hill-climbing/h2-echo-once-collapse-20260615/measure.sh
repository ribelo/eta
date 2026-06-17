#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_ONCE_REQUESTS:-4000}"
CONCURRENCY="${ETA_H2_ONCE_CONCURRENCY:-16}"
REPEATS="${ETA_H2_ONCE_REPEATS:-5}"
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

run_case() {
  local case_name="$1"
  local path="$2"
  local repeat="$3"
  local port=$((18000 + RANDOM % 20000))
  local server_tmp="$TMP_DIR/server-$case_name-$repeat"
  local server_log="$RESULT_DIR/server-$case_name-$repeat.log"
  local trace="$RESULT_DIR/server-trace-$case_name-$repeat.log"
  local client_tsv="$RESULT_DIR/client-$case_name-$repeat.tsv"
  mkdir -p "$server_tmp"

  echo "$case_name repeat $repeat/$REPEATS: starting traced H2C probe on port $port" >&2
  ETA_H2_ECHO_TRACE_PATH="$trace" \
    _build/default/http-testsuite/test/server_load/h2_probe.exe \
    "$port" "$server_tmp" >"$server_log" 2>&1 &
  SERVER_PID="$!"

  local ready=0
  for _ in $(seq 1 200); do
    if grep -q "READY $port" "$server_log"; then
      ready=1
      break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "server exited before ready" >&2
      cat "$server_log" >&2
      exit 1
    fi
    sleep 0.05
  done
  if [[ "$ready" -ne 1 ]]; then
    echo "server did not become ready" >&2
    cat "$server_log" >&2
    exit 1
  fi

  _build/default/http-testsuite/test/server_load/h2_gap_client.exe \
    127.0.0.1 "$port" "$REQUESTS" "$CONCURRENCY" 1 "$client_tsv" "$path"
  cleanup_server
}

for repeat in $(seq 1 "$REPEATS"); do
  run_case echo /echo "$repeat"
  run_case echo_once /echo_once "$repeat"
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
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil((p / 100.0) * len(ordered)) - 1))
    return ordered[index]

def median(values):
    return statistics.median(values)

def parse_client(path):
    totals = []
    with path.open(newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            if int(row["status"]) != 200 or int(row["bytes"]) != 1024 or row["error"]:
                raise SystemExit(f"bad client row in {path}: {row}")
            totals.append(int(row["t3_us"]) - int(row["t0_us"]))
    if len(totals) != requests:
        raise SystemExit(f"{path} expected {requests} rows, saw {len(totals)}")
    return totals

def parse_trace(path, handler_event):
    body = []
    returns = {}
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
            if event == handler_event:
                body.append(fields["request_body_read_us"])
            elif event == "h2_request_body_read_return":
                match = result_re.search(line)
                result = match.group(1) if match else "unknown"
                entry = returns.setdefault(stream_id, {"chunk": 0, "eof": 0, "error": 0})
                if result in entry:
                    entry[result] += 1
    if len(body) != requests:
        raise SystemExit(f"{path} expected {requests} handler rows, saw {len(body)}")
    return body, returns

summaries = []
for repeat in range(1, repeats + 1):
    row = {"repeat": repeat}
    for case_name, handler_event in [("echo", "echo_handler"), ("echo_once", "echo_once_handler")]:
        client_totals = parse_client(result_dir / f"client-{case_name}-{repeat}.tsv")
        body_times, returns = parse_trace(
            result_dir / f"server-trace-{case_name}-{repeat}.log",
            handler_event,
        )
        eof_count = sum(item["eof"] for item in returns.values())
        chunk_count = sum(item["chunk"] for item in returns.values())
        row[f"{case_name}_client_p99_us"] = pct(client_totals, 99)
        row[f"{case_name}_client_p995_us"] = pct(client_totals, 99.5)
        row[f"{case_name}_body_p50_us"] = pct(body_times, 50)
        row[f"{case_name}_body_p95_us"] = pct(body_times, 95)
        row[f"{case_name}_body_p99_us"] = pct(body_times, 99)
        row[f"{case_name}_body_p995_us"] = pct(body_times, 99.5)
        row[f"{case_name}_body_max_us"] = max(body_times)
        row[f"{case_name}_chunk_returns_per_stream"] = chunk_count / requests
        row[f"{case_name}_eof_returns_per_stream"] = eof_count / requests
    row["body_p99_ratio"] = row["echo_once_body_p99_us"] / row["echo_body_p99_us"]
    row["client_p99_ratio"] = row["echo_once_client_p99_us"] / row["echo_client_p99_us"]
    summaries.append(row)

summary_path = result_dir / "collapse-summary.tsv"
fields = [
    "repeat",
    "echo_body_p99_us",
    "echo_once_body_p99_us",
    "body_p99_ratio",
    "echo_client_p99_us",
    "echo_once_client_p99_us",
    "client_p99_ratio",
    "echo_eof_returns_per_stream",
    "echo_once_eof_returns_per_stream",
]
with summary_path.open("w", newline="") as f:
    writer = csv.DictWriter(f, delimiter="\t", fieldnames=fields)
    writer.writeheader()
    for row in summaries:
        writer.writerow({field: row[field] for field in fields})

print("repeat\techo_body_p99_us\techo_once_body_p99_us\tbody_ratio\techo_client_p99_us\techo_once_client_p99_us\tclient_ratio\techo_eof_per_stream\tonce_eof_per_stream")
for row in summaries:
    print(
        f"{row['repeat']}\t"
        f"{row['echo_body_p99_us']}\t"
        f"{row['echo_once_body_p99_us']}\t"
        f"{row['body_p99_ratio']:.3f}\t"
        f"{row['echo_client_p99_us']}\t"
        f"{row['echo_once_client_p99_us']}\t"
        f"{row['client_p99_ratio']:.3f}\t"
        f"{row['echo_eof_returns_per_stream']:.1f}\t"
        f"{row['echo_once_eof_returns_per_stream']:.1f}"
    )

metrics = {
    "h2_echo_body_p99_us": median(row["echo_body_p99_us"] for row in summaries),
    "h2_echo_once_body_p99_us": median(row["echo_once_body_p99_us"] for row in summaries),
    "h2_echo_once_body_p99_ratio": median(row["body_p99_ratio"] for row in summaries),
    "h2_echo_client_p99_us": median(row["echo_client_p99_us"] for row in summaries),
    "h2_echo_once_client_p99_us": median(row["echo_once_client_p99_us"] for row in summaries),
    "h2_echo_once_client_p99_ratio": median(row["client_p99_ratio"] for row in summaries),
    "h2_echo_eof_returns_per_stream": median(row["echo_eof_returns_per_stream"] for row in summaries),
    "h2_echo_once_eof_returns_per_stream": median(row["echo_once_eof_returns_per_stream"] for row in summaries),
    "h2_echo_once_success": 1.0,
}
for name, value in metrics.items():
    print(f"METRIC {name}={value:.6f}")
print(f"collapse summary: {summary_path}", file=sys.stderr)
PY
