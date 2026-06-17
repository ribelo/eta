#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_TLS_AGG_REQUESTS:-12000}"
CONNECTIONS="${ETA_TLS_AGG_CONNECTIONS:-16}"
H2_CONNECTIONS="${ETA_TLS_AGG_H2_CONNECTIONS:-1}"
H2_STREAMS="${ETA_TLS_AGG_H2_STREAMS:-16}"
REPEATS="${ETA_TLS_AGG_REPEATS:-1}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/tls-aggregate-results/$STAMP"
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

PORT=$((28000 + RANDOM % 9000))
DIRECT_DIR="$RESULT_DIR/direct-tls-split"
mkdir -p "$DIRECT_DIR" "$TMP_DIR/direct-server"

ETA_TLS_AGG_TRACE_PATH="$DIRECT_DIR/tls-agg.log" \
ETA_TINY_TLS_SPLIT_SERVER=1 \
  taskset -c "${ETA_SERVER_LOAD_SERVER_CORE:-2}" \
  _build/default/http-testsuite/test/server_load/tiny_tls_probe.exe \
  server "$PORT" "$TMP_DIR/direct-server" tls \
  >"$DIRECT_DIR/server.log" 2>&1 &
SERVER_PID="$!"

ready=0
for _ in $(seq 1 200); do
  if grep -q "READY $PORT" "$DIRECT_DIR/server.log"; then
    ready=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$DIRECT_DIR/server.log" >&2
    exit 1
  fi
  sleep 0.05
done
if [[ "$ready" -ne 1 ]]; then
  cat "$DIRECT_DIR/server.log" >&2
  exit 1
fi

taskset -c "${ETA_SERVER_LOAD_LOAD_CORE:-3}" \
  _build/default/http-testsuite/test/server_load/tiny_tls_probe.exe \
  client 127.0.0.1 "$PORT" "$REQUESTS" "$CONNECTIONS" "$REPEATS" \
  "$DIRECT_DIR/client.tsv" tls "$TMP_DIR/direct-server/certs/ca.pem"

cleanup_server

H2_OUT="$RESULT_DIR/h2-root-trace.tsv"
ETA_TLS_AGG_TRACE_PATH="$RESULT_DIR/h2-tls-agg.log" \
ETA_H2_16X1_TRACE_REQUESTS="$REQUESTS" \
ETA_H2_16X1_CONNECTIONS="$H2_CONNECTIONS" \
ETA_H2_16X1_STREAMS="$H2_STREAMS" \
ETA_H2_16X1_TRACE_MODE=tls \
  bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_tls.sh \
  >"$H2_OUT"

cat "$H2_OUT"

python3 - "$DIRECT_DIR/client.tsv" "$DIRECT_DIR/tls-agg.log" "$H2_OUT" "$RESULT_DIR/h2-tls-agg.log" <<'PY'
import csv
import math
import re
import sys
from pathlib import Path

direct_client = Path(sys.argv[1])
direct_agg = Path(sys.argv[2])
h2_trace = Path(sys.argv[3])
h2_agg = Path(sys.argv[4])

kv_pattern = re.compile(r"([a-zA-Z0-9_]+)=(-?\d+(?:\.\d+)?)")

def pct(values, percentile):
    if not values:
        return 0
    ordered = sorted(values)
    index = max(
        0,
        min(len(ordered) - 1, math.ceil((percentile / 100.0) * len(ordered)) - 1),
    )
    return ordered[index]

def latest_agg_rows(path):
    by_id = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if "tls_agg_probe" not in line:
                continue
            row = {}
            for key, value in kv_pattern.findall(line):
                row[key] = float(value)
            probe_id = int(row.get("probe_id", -1))
            if probe_id < 0:
                continue
            previous = by_id.get(probe_id)
            if previous is None or row.get("raw_writes", 0) >= previous.get("raw_writes", 0):
                by_id[probe_id] = row
    return list(by_id.values())

def agg_metrics(rows, prefix):
    def vals(name):
        return [row[name] for row in rows if name in row]

    raw_writes = sum(vals("raw_writes"))
    metrics = {
        f"{prefix}_tls_agg_connections": len(rows),
        f"{prefix}_tls_agg_raw_writes": raw_writes,
        f"{prefix}_tls_agg_single_write_p99_conn_max_us": max(vals("single_write_p99_us") or [0]),
        f"{prefix}_tls_agg_single_write_p99_conn_median_us": pct(vals("single_write_p99_us"), 50),
        f"{prefix}_tls_agg_ssl_write_p99_conn_max_us": max(vals("ssl_write_p99_us") or [0]),
        f"{prefix}_tls_agg_drain_bio_p99_conn_max_us": max(vals("drain_bio_p99_us") or [0]),
        f"{prefix}_tls_agg_write_mutex_wait_p99_conn_max_us": max(vals("write_mutex_wait_p99_us") or [0]),
        f"{prefix}_tls_agg_raw_write_p99_conn_max_us": max(vals("raw_write_p99_us") or [0]),
        f"{prefix}_tls_agg_raw_write_p99_conn_median_us": pct(vals("raw_write_p99_us"), 50),
        f"{prefix}_tls_agg_raw_write_bytes_p99_conn_max": max(vals("raw_write_bytes_p99") or [0]),
        f"{prefix}_tls_agg_want_read": sum(vals("want_read")),
        f"{prefix}_tls_agg_want_write": sum(vals("want_write")),
    }
    return metrics

direct_totals = []
direct_errors = 0
with direct_client.open() as f:
    reader = csv.DictReader(f, delimiter="\t")
    for row in reader:
        if row["error"]:
            direct_errors += 1
            continue
        direct_totals.append(int(row["t2_us"]) - int(row["t0_us"]))

h2_values = {}
for line in h2_trace.read_text().splitlines():
    parts = line.split("\t")
    if len(parts) == 2:
        try:
            h2_values[parts[0]] = float(parts[1])
        except ValueError:
            pass
    elif len(parts) == 7 and parts[0] == "write_complete_response_us":
        h2_values["write_complete_response_p99_us"] = float(parts[4])
    elif len(parts) == 7 and parts[0] == "flow_write_us":
        h2_values["flow_write_p99_us"] = float(parts[4])
    elif len(parts) == 7 and parts[0] == "write_job_wait_us":
        h2_values["write_job_wait_p99_us"] = float(parts[4])

metrics = {
    "direct_tls_total_p50_us": pct(direct_totals, 50),
    "direct_tls_total_p95_us": pct(direct_totals, 95),
    "direct_tls_total_p99_us": pct(direct_totals, 99),
    "direct_tls_errors": direct_errors,
    "h2_tls_oha_p99_us": h2_values.get("oha_p99_us", 0),
    "h2_tls_write_complete_response_p99_us": h2_values.get("write_complete_response_p99_us", 0),
    "h2_tls_flow_write_p99_us": h2_values.get("flow_write_p99_us", 0),
    "h2_tls_write_job_wait_p99_us": h2_values.get("write_job_wait_p99_us", 0),
}
metrics.update(agg_metrics(latest_agg_rows(direct_agg), "direct"))
metrics.update(agg_metrics(latest_agg_rows(h2_agg), "h2"))

print(f"tls_aggregate_result_dir\t{h2_agg.parent}")
print(
    "tls_aggregate_summary\t"
    f"direct_total_p99_us={metrics['direct_tls_total_p99_us']:.0f}\t"
    f"direct_raw_write_p99_conn_max_us={metrics['direct_tls_agg_raw_write_p99_conn_max_us']:.0f}\t"
    f"h2_oha_p99_us={metrics['h2_tls_oha_p99_us']:.0f}\t"
    f"h2_flow_write_p99_us={metrics['h2_tls_flow_write_p99_us']:.0f}\t"
    f"h2_raw_write_p99_conn_max_us={metrics['h2_tls_agg_raw_write_p99_conn_max_us']:.0f}\t"
    f"h2_ssl_write_p99_conn_max_us={metrics['h2_tls_agg_ssl_write_p99_conn_max_us']:.0f}\t"
    f"h2_write_mutex_wait_p99_conn_max_us={metrics['h2_tls_agg_write_mutex_wait_p99_conn_max_us']:.0f}"
)

success = 1 if direct_errors == 0 and metrics["direct_tls_agg_connections"] > 0 and metrics["h2_tls_agg_connections"] > 0 else 0
metrics["tls_aggregate_success"] = success
for name, value in metrics.items():
    print(f"METRIC {name}={float(value):.6f}")
PY
