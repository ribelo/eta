#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_16X1_PERF_REQUESTS:-24000}"
MODE="${ETA_H2_16X1_TRACE_MODE:-tls}"
STAMP="$(date +%Y%m%d-%H%M%S)"
RESULT_DIR="$SESSION_DIR/perf-sched-results/$STAMP"
PERF_DATA="$RESULT_DIR/perf.data"
CUSTOM_OUT="$RESULT_DIR/custom-client.tsv"
CUSTOM_ERR="$RESULT_DIR/custom-client.err"
PERF_ERR="$RESULT_DIR/perf-record.err"
LATENCY_OUT="$RESULT_DIR/perf-sched-latency.txt"
SCRIPT_OUT="$RESULT_DIR/perf-script.txt"

cd "$ROOT"
mkdir -p "$RESULT_DIR"

if ! command -v perf >/dev/null 2>&1; then
  echo "perf_sched_result_dir	$RESULT_DIR"
  echo "perf_available	0"
  echo "perf_reason	perf-not-found"
  exit 0
fi

echo "perf_sched_result_dir	$RESULT_DIR"
cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null \
  | awk '{ print "perf_event_paranoid\t" $1 }' || true

set +e
perf sched record -o "$PERF_DATA" -- \
  env ETA_H2_16X1_CUSTOM_REQUESTS="$REQUESTS" \
      ETA_H2_16X1_TRACE_MODE="$MODE" \
      bash "$SESSION_DIR/trace_root_custom_client_16x1.sh" \
      >"$CUSTOM_OUT" 2>"$CUSTOM_ERR"
record_status=$?
set -e

if [[ "$record_status" -ne 0 ]]; then
  echo "perf_available	0"
  echo "perf_record_status	$record_status"
  echo "perf_reason	record-failed"
  if [[ -f "$CUSTOM_ERR" ]]; then
    sed -n '1,120p' "$CUSTOM_ERR" >"$RESULT_DIR/custom-client.err.head"
  fi
  if [[ -f "$PERF_ERR" ]]; then
    sed -n '1,120p' "$PERF_ERR" >"$RESULT_DIR/perf-record.err.head"
  fi
  exit 0
fi

perf sched latency -i "$PERF_DATA" >"$LATENCY_OUT" 2>"$RESULT_DIR/perf-latency.err" || true
perf script -i "$PERF_DATA" >"$SCRIPT_OUT" 2>"$RESULT_DIR/perf-script.err" || true

python - "$CUSTOM_OUT" "$LATENCY_OUT" "$SCRIPT_OUT" <<'PY'
import re
import sys
from pathlib import Path

custom_path = Path(sys.argv[1])
latency_path = Path(sys.argv[2])
script_path = Path(sys.argv[3])

def read_tsv(path):
    out = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        if "\t" not in line:
            continue
        key, value = line.split("\t", 1)
        out[key] = value
    return out

custom = read_tsv(custom_path)
latency_text = latency_path.read_text(errors="replace") if latency_path.exists() else ""
script_lines = script_path.read_text(errors="replace").splitlines() if script_path.exists() else []

eta_lines = [
    line for line in latency_text.splitlines()
    if "h2_" in line or "h2_tls_probe" in line or "h2_probe" in line or "h2_gap_client" in line
]
sched_switches = sum(1 for line in script_lines if "sched_switch" in line)

print("perf_available\t1")
print(f"custom_success\t{custom.get('success', '0')}")
print(f"custom_total_p99_us\t{custom.get('total_us_p99_us', '0')}")
print(f"custom_t1_t2_p99_us\t{custom.get('t1_t2_us_p99_us', '0')}")
print(
    "custom_response_to_flow_p99_us\t"
    f"{custom.get('response_start_to_flow_complete_us_p99_us', '0')}"
)
print(
    "custom_flow_to_rx_p99_us\t"
    f"{custom.get('flow_complete_to_rx_headers_us_p99_us', '0')}"
)
print(f"perf_sched_switch_events\t{sched_switches}")
print(f"perf_latency_eta_lines\t{len(eta_lines)}")
print("perf_latency_top")
for line in eta_lines[:20]:
    print(re.sub(r"\s+", " ", line.strip()))
PY
