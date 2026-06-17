#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_RUNTIME_REQUESTS:-12000}"
CONNECTIONS="${ETA_H2_RUNTIME_CONNECTIONS:-16}"
STREAMS="${ETA_H2_RUNTIME_STREAMS:-1}"
MODE="${ETA_H2_RUNTIME_MODE:-tls}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/runtime-probe-results/$STAMP"

cd "$ROOT"
mkdir -p "$RESULT_DIR"

TRACE_OUT="$RESULT_DIR/root-trace.tsv"
RUNTIME_LOG="$RESULT_DIR/runtime.log"

ETA_H2_RUNTIME_TRACE_PATH="$RUNTIME_LOG" \
ETA_H2_16X1_TRACE_REQUESTS="$REQUESTS" \
ETA_H2_16X1_CONNECTIONS="$CONNECTIONS" \
ETA_H2_16X1_STREAMS="$STREAMS" \
ETA_H2_16X1_TRACE_MODE="$MODE" \
  bash .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_tls.sh \
  >"$TRACE_OUT"

cat "$TRACE_OUT"

python3 - "$RUNTIME_LOG" "$TRACE_OUT" "$REQUESTS" "$CONNECTIONS" <<'PY'
import math
import re
import sys
from pathlib import Path

runtime_path = Path(sys.argv[1])
trace_path = Path(sys.argv[2])
expected_requests = int(sys.argv[3])
expected_connections = int(sys.argv[4])

kv_pattern = re.compile(r"([a-zA-Z0-9_]+)=(-?\d+(?:\.\d+)?)")
connection_pattern = re.compile(r"connection_id=([^ ]+)")

rows_by_connection = {}
if runtime_path.exists():
    for line in runtime_path.read_text().splitlines():
        if "h2_runtime_probe" not in line:
            continue
        connection_match = connection_pattern.search(line)
        connection_id = connection_match.group(1) if connection_match else line
        row = {}
        for key, value in kv_pattern.findall(line):
            row[key] = float(value)
        previous = rows_by_connection.get(connection_id)
        if previous is None or row.get("handler_completed", 0) >= previous.get("handler_completed", 0):
            rows_by_connection[connection_id] = row

rows = list(rows_by_connection.values())

trace_values = {}
for line in trace_path.read_text().splitlines():
    parts = line.split("\t")
    if len(parts) == 2:
        try:
            trace_values[parts[0]] = float(parts[1])
        except ValueError:
            pass
    elif len(parts) == 7 and parts[0] in {
        "write_complete_response_us",
        "flow_write_us",
        "write_job_wait_us",
        "ingress_owner_ack_us",
    }:
        trace_values[f"{parts[0]}_p99"] = float(parts[4])

def values(name):
    return [row[name] for row in rows if name in row]

def total(name):
    return sum(values(name))

def vmax(name):
    vals = values(name)
    return max(vals) if vals else 0.0

def median(vals):
    if not vals:
        return 0.0
    ordered = sorted(vals)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0

def vmedian(name):
    return median(values(name))

requests = int(total("requests"))
success = (
    1
    if len(rows) == expected_connections and requests >= math.floor(expected_requests * 0.8)
    else 0
)
minor_words = total("minor_words_delta")
major_words = total("major_words_delta")

print(f"runtime_probe_result_dir\t{runtime_path.parent}")
print(f"runtime_probe_connections\t{len(rows)}")
print(f"runtime_probe_requests\t{requests}")
print(
    "runtime_probe_summary\t"
    f"handler_queue_p99_max_us={vmax('handler_queue_p99_us'):.0f}\t"
    f"handler_runtime_p99_max_us={vmax('handler_runtime_p99_us'):.0f}\t"
    f"handler_prepare_p99_max_us={vmax('handler_prepare_p99_us'):.0f}\t"
    f"response_owner_wait_p99_max_us={vmax('response_owner_wait_p99_us'):.0f}\t"
    f"handler_total_p99_max_us={vmax('handler_total_p99_us'):.0f}\t"
    f"minor_words_per_request={(minor_words / requests) if requests else 0:.1f}\t"
    f"major_words_per_request={(major_words / requests) if requests else 0:.1f}"
)

metrics = {
    "h2_runtime_probe_success": success,
    "h2_runtime_probe_connections": len(rows),
    "h2_runtime_probe_requests": requests,
    "h2_runtime_handler_queue_p99_conn_max_us": vmax("handler_queue_p99_us"),
    "h2_runtime_handler_queue_p99_conn_median_us": vmedian("handler_queue_p99_us"),
    "h2_runtime_handler_runtime_p99_conn_max_us": vmax("handler_runtime_p99_us"),
    "h2_runtime_handler_runtime_p99_conn_median_us": vmedian("handler_runtime_p99_us"),
    "h2_runtime_handler_prepare_p99_conn_max_us": vmax("handler_prepare_p99_us"),
    "h2_runtime_response_owner_wait_p99_conn_max_us": vmax("response_owner_wait_p99_us"),
    "h2_runtime_response_owner_wait_p99_conn_median_us": vmedian("response_owner_wait_p99_us"),
    "h2_runtime_handler_total_p99_conn_max_us": vmax("handler_total_p99_us"),
    "h2_runtime_minor_words_per_request": (minor_words / requests) if requests else 0.0,
    "h2_runtime_major_words_per_request": (major_words / requests) if requests else 0.0,
    "h2_runtime_minor_collections_total": total("minor_collections_delta"),
    "h2_runtime_major_collections_total": total("major_collections_delta"),
}

for key in [
    "oha_p99_us",
    "write_complete_response_us_p99",
    "flow_write_us_p99",
    "write_job_wait_us_p99",
    "ingress_owner_ack_us_p99",
]:
    if key in trace_values:
        metrics[f"h2_runtime_trace_{key}"] = trace_values[key]

for name, value in metrics.items():
    print(f"METRIC {name}={float(value):.6f}")
PY
