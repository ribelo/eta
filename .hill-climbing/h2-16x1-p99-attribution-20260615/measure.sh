#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_16X1_REQUESTS:-24000}"
REPEATS="${ETA_H2_16X1_REPEATS:-9}"
BROAD_REQUESTS="${ETA_H2_16X1_BROAD_REQUESTS:-3200}"
BROAD_REPEATS="${ETA_H2_16X1_BROAD_REPEATS:-3}"
TIMEOUT="${ETA_H2_16X1_TIMEOUT:-10s}"
CONNECTIONS="${ETA_H2_16X1_CONNECTIONS:-16}"
STREAMS="${ETA_H2_16X1_STREAMS:-1}"
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

bool_env() {
  local name="$1"
  local default="$2"
  local value="${!name:-$default}"
  case "${value,,}" in
    0|false|no|off) return 1 ;;
    *) return 0 ;;
  esac
}

have_command() {
  command -v "$1" >/dev/null 2>&1
}

cd "$ROOT"
mkdir -p "$RESULT_DIR"

if ! have_command oha; then
  echo "oha is required for this hill" >&2
  exit 2
fi

echo "building H2 probes" >&2
nix develop -c dune build \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_tls_probe.exe

BODY_1K="$TMP_DIR/body-echo-1k.bin"
python - "$BODY_1K" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(b"x" * 1024)
PY

SERVER_CORE="${ETA_SERVER_LOAD_SERVER_CORE:-2}"
LOAD_CORE="${ETA_SERVER_LOAD_LOAD_CORE:-3}"

start_server() {
  local mode="$1"
  cleanup_server
  local port=$((18000 + RANDOM % 20000))
  local server_tmp="$TMP_DIR/server-$mode"
  local server_log="$RESULT_DIR/server-$mode.log"
  mkdir -p "$server_tmp"

  local probe="_build/default/http-testsuite/test/server_load/h2_probe.exe"
  if [[ "$mode" == "tls" ]]; then
    probe="_build/default/http-testsuite/test/server_load/h2_tls_probe.exe"
  fi

  local server_cmd=("$probe")
  if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
    server_cmd=(taskset -c "$SERVER_CORE" "${server_cmd[@]}")
  fi

  "${server_cmd[@]}" "$port" "$server_tmp" >"$server_log" 2>&1 &
  SERVER_PID="$!"

  local ready=0
  for _ in $(seq 1 200); do
    if grep -q "READY $port" "$server_log"; then
      ready=1
      break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      echo "$mode server exited before ready" >&2
      sed -n '1,160p' "$server_log" >&2
      exit 1
    fi
    sleep 0.05
  done

  if [[ "$ready" -ne 1 ]]; then
    echo "$mode server did not become ready" >&2
    sed -n '1,160p' "$server_log" >&2
    exit 1
  fi

  printf '%s' "$port"
}

run_oha() {
  local mode="$1"
  local phase="$2"
  local endpoint="$3"
  local method="$4"
  local path="$5"
  local body_file="$6"
  local requests="$7"
  local repeat="$8"
  local port="$9"
  local raw="$RESULT_DIR/${phase}-${mode}-${endpoint}-${repeat}.json"
  local err="$RESULT_DIR/${phase}-${mode}-${endpoint}-${repeat}.err"
  local scheme="http"
  local tls_flags=()
  if [[ "$mode" == "tls" ]]; then
    scheme="https"
    tls_flags=(--insecure)
  fi
  local url="${scheme}://127.0.0.1:${port}${path}"
  local cmd=(
    oha
    --no-tui
    --output-format json
    --redirect 0
    --disable-compression
    --connect-timeout 2s
    -t "$TIMEOUT"
    -c "$CONNECTIONS"
    -p "$STREAMS"
    -n "$requests"
    --http-version 2
    "${tls_flags[@]}"
  )

  if [[ "$method" == "POST" ]]; then
    cmd+=(-m POST -T text/plain)
    if [[ -n "$body_file" ]]; then
      cmd+=(-D "$body_file")
    fi
  fi
  cmd+=("$url")

  local runner=()
  if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
    runner=(taskset -c "$LOAD_CORE")
  fi
  env NO_COLOR=false "${runner[@]}" "${cmd[@]}" >"$raw" 2>"$err"
}

run_endpoint_set() {
  local mode="$1"
  local phase="$2"
  local requests="$3"
  local repeats="$4"
  local port="$5"
  for repeat in $(seq 1 "$repeats"); do
    echo "$mode $phase repeat $repeat/$repeats: H2 16x1 root/user/post/static/echo" >&2
    run_oha "$mode" "$phase" root GET / "" "$requests" "$repeat" "$port"
    run_oha "$mode" "$phase" user_id GET /user/123 "" "$requests" "$repeat" "$port"
    run_oha "$mode" "$phase" post_user POST /user "" "$requests" "$repeat" "$port"
    run_oha "$mode" "$phase" static_1k GET /static/1k.bin "" "$requests" "$repeat" "$port"
    run_oha "$mode" "$phase" echo_1k POST /echo "$BODY_1K" "$requests" "$repeat" "$port"
  done
}

run_broad_root() {
  local mode="$1"
  local requests="$2"
  local repeats="$3"
  local port="$4"
  for repeat in $(seq 1 "$repeats"); do
    echo "$mode broad-floor repeat $repeat/$repeats: H2 16x1 root" >&2
    run_oha "$mode" broad root GET / "" "$requests" "$repeat" "$port"
  done
}

TLS_PORT="$(start_server tls)"
run_endpoint_set tls steady "$REQUESTS" "$REPEATS" "$TLS_PORT"
run_broad_root tls "$BROAD_REQUESTS" "$BROAD_REPEATS" "$TLS_PORT"
cleanup_server

PLAIN_PORT="$(start_server plain)"
run_endpoint_set plain steady "$REQUESTS" "$REPEATS" "$PLAIN_PORT"
run_broad_root plain "$BROAD_REQUESTS" "$BROAD_REPEATS" "$PLAIN_PORT"
cleanup_server

python - "$RESULT_DIR" "$REQUESTS" "$REPEATS" "$BROAD_REQUESTS" "$BROAD_REPEATS" <<'PY'
import csv
import json
import math
import statistics
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
steady_requests = int(sys.argv[2])
steady_repeats = int(sys.argv[3])
broad_requests = int(sys.argv[4])
broad_repeats = int(sys.argv[5])

endpoints = [
    ("root", 0),
    ("user_id", 3),
    ("post_user", 0),
    ("static_1k", 1024),
    ("echo_1k", 1024),
]
modes = ["tls", "plain"]

def number(value, default=0.0):
    if value is None:
        return default
    return float(value)

def median(values):
    return statistics.median(values)

def geomean(values):
    if any(value <= 0 for value in values):
        return 0.0
    return math.exp(sum(math.log(value) for value in values) / len(values))

def read_row(phase, mode, endpoint, expected_body_bytes, requests, repeat):
    raw_path = result_dir / f"{phase}-{mode}-{endpoint}-{repeat}.json"
    try:
        raw = json.loads(raw_path.read_text())
    except Exception as exc:
        raise SystemExit(f"could not parse {raw_path}: {exc}") from exc
    summary = raw.get("summary", {})
    latency = raw.get("latencyPercentiles", {})
    status_dist = raw.get("statusCodeDistribution", {})
    error_dist = raw.get("errorDistribution", {})
    total_requests = sum(int(value) for value in status_dist.values())
    errors = sum(int(value) for value in error_dist.values())
    ok_count = int(status_dist.get("200", 0))
    total_data = int(number(summary.get("totalData")))
    expected_total_data = requests * expected_body_bytes
    endpoint_success = (
        ok_count == requests
        and total_requests == requests
        and errors == 0
        and number(summary.get("successRate")) == 1.0
        and total_data == expected_total_data
    )
    return {
        "phase": phase,
        "mode": mode,
        "repeat": repeat,
        "endpoint": endpoint,
        "success": 1 if endpoint_success else 0,
        "requests": requests,
        "rps": number(summary.get("requestsPerSec")),
        "p50_us": number(latency.get("p50")) * 1_000_000.0,
        "p95_us": number(latency.get("p95")) * 1_000_000.0,
        "p99_us": number(latency.get("p99")) * 1_000_000.0,
        "p999_us": number(latency.get("p99.9")) * 1_000_000.0,
        "max_us": number(summary.get("slowest")) * 1_000_000.0,
        "total_data": total_data,
    }

rows = []
for mode in modes:
    for repeat in range(1, steady_repeats + 1):
        for endpoint, expected_body_bytes in endpoints:
            rows.append(
                read_row(
                    "steady", mode, endpoint, expected_body_bytes,
                    steady_requests, repeat
                )
            )
    for repeat in range(1, broad_repeats + 1):
        rows.append(read_row("broad", mode, "root", 0, broad_requests, repeat))

summary_path = result_dir / "h2-16x1-summary.tsv"
with summary_path.open("w", newline="") as f:
    fieldnames = [
        "phase",
        "mode",
        "repeat",
        "endpoint",
        "success",
        "requests",
        "rps",
        "p50_us",
        "p95_us",
        "p99_us",
        "p999_us",
        "max_us",
        "total_data",
    ]
    writer = csv.DictWriter(f, delimiter="\t", fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)

success = all(row["success"] == 1 for row in rows)
steady_rows = [row for row in rows if row["phase"] == "steady"]
broad_rows = [row for row in rows if row["phase"] == "broad"]

metrics = {
    "h2_16x1_success": 1.0 if success else 0.0,
}

print("phase\tmode\tendpoint\tp50_us\tp95_us\tp99_us\tp999_us\tmax_us\trps\trepeats")
for phase, phase_rows in [("steady", steady_rows), ("broad", broad_rows)]:
    phase_modes = modes
    for mode in phase_modes:
        phase_mode_rows = [row for row in phase_rows if row["mode"] == mode]
        phase_endpoints = endpoints if phase == "steady" else [("root", 0)]
        if phase == "steady":
            repeat_geomeans = []
            repeat_count = steady_repeats
            for repeat in range(1, repeat_count + 1):
                repeat_rows = [
                    row for row in phase_mode_rows if row["repeat"] == repeat
                ]
                repeat_geomeans.append(geomean([row["rps"] for row in repeat_rows]))
            metrics[f"h2_{mode}_16x1_rps_geomean"] = median(repeat_geomeans)
        for endpoint, _ in phase_endpoints:
            endpoint_rows = [
                row for row in phase_mode_rows if row["endpoint"] == endpoint
            ]
            p99s = [row["p99_us"] for row in endpoint_rows]
            repeat_text = ",".join(f"{value:.0f}" for value in p99s)
            prefix = f"h2_{mode}_16x1_{endpoint}"
            if phase == "broad":
                prefix += "_broad"
            metrics[f"{prefix}_p50_us"] = median(
                [row["p50_us"] for row in endpoint_rows]
            )
            metrics[f"{prefix}_p95_us"] = median(
                [row["p95_us"] for row in endpoint_rows]
            )
            metrics[f"{prefix}_p99_us"] = median(p99s)
            metrics[f"{prefix}_p999_us"] = median(
                [row["p999_us"] for row in endpoint_rows]
            )
            metrics[f"{prefix}_max_us"] = max(row["max_us"] for row in endpoint_rows)
            metrics[f"{prefix}_rps"] = median([row["rps"] for row in endpoint_rows])
            print(
                f"{phase}\t{mode}\t{endpoint}\t"
                f"{metrics[f'{prefix}_p50_us']:.0f}\t"
                f"{metrics[f'{prefix}_p95_us']:.0f}\t"
                f"{metrics[f'{prefix}_p99_us']:.0f}\t"
                f"{metrics[f'{prefix}_p999_us']:.0f}\t"
                f"{metrics[f'{prefix}_max_us']:.0f}\t"
                f"{metrics[f'{prefix}_rps']:.0f}\t"
                f"{repeat_text}"
            )

steady_root = metrics["h2_tls_16x1_root_p99_us"]
broad_root = metrics["h2_tls_16x1_root_broad_p99_us"]
metrics["h2_tls_16x1_root_broad_to_steady_p99_ratio"] = (
    broad_root / steady_root if steady_root > 0 else 0.0
)

for name, value in metrics.items():
    print(f"METRIC {name}={value:.6f}")
print(f"h2 16x1 summary: {summary_path}", file=sys.stderr)
PY
