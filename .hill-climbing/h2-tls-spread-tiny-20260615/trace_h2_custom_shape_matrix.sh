#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_SHAPE_MATRIX_REQUESTS:-12000}"
REPEATS="${ETA_H2_SHAPE_MATRIX_REPEATS:-1}"
PATH_UNDER_TEST="${ETA_H2_SHAPE_MATRIX_PATH:-/}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/custom-h2-shape-matrix-results/$STAMP"
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
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_tls_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

run_case() {
  local mode="$1"
  local connections="$2"
  local streams="$3"
  local label="${mode}-${connections}x${streams}"
  local case_dir="$RESULT_DIR/$label"
  local temp_dir="$TMP_DIR/$label"
  local port=$((29000 + RANDOM % 8000))
  local server_log="$case_dir/server.log"
  local probe="_build/default/http-testsuite/test/server_load/h2_probe.exe"
  local requests_per_connection

  if (( REQUESTS % connections != 0 )); then
    echo "REQUESTS=$REQUESTS must be divisible by connections=$connections" >&2
    exit 2
  fi
  requests_per_connection=$((REQUESTS / connections))

  mkdir -p "$case_dir" "$temp_dir/server"
  if [[ "$mode" == "tls" ]]; then
    probe="_build/default/http-testsuite/test/server_load/h2_tls_probe.exe"
  elif [[ "$mode" != "plain" ]]; then
    echo "mode must be tls or plain" >&2
    exit 2
  fi

  taskset -c "${ETA_SERVER_LOAD_SERVER_CORE:-2}" \
    "$probe" "$port" "$temp_dir/server" >"$server_log" 2>&1 &
  SERVER_PID="$!"

  local ready=0
  for _ in $(seq 1 200); do
    if grep -q "READY $port" "$server_log"; then
      ready=1
      break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      cat "$server_log" >&2
      exit 1
    fi
    sleep 0.05
  done
  if [[ "$ready" -ne 1 ]]; then
    cat "$server_log" >&2
    exit 1
  fi

  local client_pids=()
  for connection in $(seq 0 $((connections - 1))); do
    if [[ "$mode" == "tls" ]]; then
      ETA_H2_GAP_TLS_CA_FILE="$temp_dir/server/certs/ca.pem" \
      ETA_H2_GAP_METHOD=GET \
      ETA_H2_GAP_BODY_BYTES=0 \
        taskset -c "${ETA_SERVER_LOAD_LOAD_CORE:-3}" \
        _build/default/http-testsuite/test/server_load/h2_gap_client.exe \
        127.0.0.1 "$port" "$requests_per_connection" "$streams" "$REPEATS" \
        "$case_dir/client-$connection.tsv" "$PATH_UNDER_TEST" \
        >"$case_dir/client-$connection.out" \
        2>"$case_dir/client-$connection.err" &
    else
      ETA_H2_GAP_METHOD=GET \
      ETA_H2_GAP_BODY_BYTES=0 \
        taskset -c "${ETA_SERVER_LOAD_LOAD_CORE:-3}" \
        _build/default/http-testsuite/test/server_load/h2_gap_client.exe \
        127.0.0.1 "$port" "$requests_per_connection" "$streams" "$REPEATS" \
        "$case_dir/client-$connection.tsv" "$PATH_UNDER_TEST" \
        >"$case_dir/client-$connection.out" \
        2>"$case_dir/client-$connection.err" &
    fi
    client_pids+=("$!")
  done

  for pid in "${client_pids[@]}"; do
    wait "$pid"
  done

  cleanup_server
}

run_case tls 1 16
run_case tls 4 4
run_case tls 16 1
run_case plain 1 16
run_case plain 4 4
run_case plain 16 1

python3 - "$RESULT_DIR" "$REQUESTS" "$REPEATS" <<'PY'
import csv
import math
import re
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
requests = int(sys.argv[2])
repeats = int(sys.argv[3])
expected = requests * repeats

def pct(values, percentile):
    if not values:
        return 0
    ordered = sorted(values)
    index = max(
        0,
        min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1),
    )
    return ordered[index]

def positive(row, key):
    value = int(row[key])
    return value if value >= 0 else None

def read_case(case_dir):
    samples = []
    errors = 0
    for path in sorted(case_dir.glob("client-*.tsv")):
        with path.open() as f:
            reader = csv.DictReader(f, delimiter="\t")
            for row in reader:
                if row["error"] or int(row["status"]) != 200:
                    errors += 1
                    continue
                t0 = positive(row, "t0_us")
                t1 = positive(row, "t1_us")
                t2 = positive(row, "t2_us")
                t3 = positive(row, "t3_us")
                rx_headers = positive(row, "rx_headers_us")
                rx_feed_start = positive(row, "rx_feed_start_us")
                rx_feed_end = positive(row, "rx_feed_end_us")
                if None in (t0, t1, t2, t3, rx_headers):
                    errors += 1
                    continue
                samples.append(
                    {
                        "t0": t0,
                        "t1": t1,
                        "t2": t2,
                        "t3": t3,
                        "rx_headers": rx_headers,
                        "rx_feed_start": rx_feed_start,
                        "rx_feed_end": rx_feed_end,
                    }
                )
    return samples, errors

def values(samples, f):
    out = []
    for sample in samples:
        value = f(sample)
        if value is not None and value >= 0:
            out.append(value)
    return out

def metric_name(label, suffix):
    safe = re.sub(r"[^a-zA-Z0-9]+", "_", label).strip("_")
    return f"shape_{safe}_{suffix}"

overall_success = 1
print(f"shape_matrix_result_dir\t{result_dir}")
print("shape\tmode\tconnections\tstreams\tsamples\terrors\ttotal_p99_us\tt1_rx_headers_p99_us\tt0_t1_p99_us\tt2_t3_p99_us\trx_feed_p99_us")
for case_dir in sorted(path for path in result_dir.iterdir() if path.is_dir()):
    label = case_dir.name
    mode, shape = label.split("-", 1)
    connections, streams = shape.split("x", 1)
    samples, errors = read_case(case_dir)
    if errors != 0 or len(samples) != expected:
        overall_success = 0
    total = values(samples, lambda s: s["t3"] - s["t0"])
    t1_rx_headers = values(samples, lambda s: s["rx_headers"] - s["t1"])
    t0_t1 = values(samples, lambda s: s["t1"] - s["t0"])
    t2_t3 = values(samples, lambda s: s["t3"] - s["t2"])
    rx_feed = values(
        samples,
        lambda s: None
        if s["rx_feed_start"] is None or s["rx_feed_end"] is None
        else s["rx_feed_end"] - s["rx_feed_start"],
    )
    row = {
        "samples": len(samples),
        "errors": errors,
        "total_p50_us": pct(total, 50),
        "total_p95_us": pct(total, 95),
        "total_p99_us": pct(total, 99),
        "t1_rx_headers_p50_us": pct(t1_rx_headers, 50),
        "t1_rx_headers_p95_us": pct(t1_rx_headers, 95),
        "t1_rx_headers_p99_us": pct(t1_rx_headers, 99),
        "t0_t1_p99_us": pct(t0_t1, 99),
        "t2_t3_p99_us": pct(t2_t3, 99),
        "rx_feed_p99_us": pct(rx_feed, 99),
    }
    print(
        f"{label}\t{mode}\t{connections}\t{streams}\t{row['samples']}\t"
        f"{errors}\t{row['total_p99_us']}\t{row['t1_rx_headers_p99_us']}\t"
        f"{row['t0_t1_p99_us']}\t{row['t2_t3_p99_us']}\t{row['rx_feed_p99_us']}"
    )
    for key, value in row.items():
        print(f"METRIC {metric_name(label, key)}={float(value):.6f}")

print(f"METRIC shape_matrix_success={float(overall_success):.6f}")
PY
