#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_ECHO_4X4_REQUESTS:-24000}"
REPEATS="${ETA_H2_ECHO_4X4_REPEATS:-9}"
TIMEOUT="${ETA_H2_ECHO_4X4_TIMEOUT:-10s}"
PRIMARY_CONNECTIONS="${ETA_H2_ECHO_4X4_CONNECTIONS:-4}"
PRIMARY_STREAMS="${ETA_H2_ECHO_4X4_STREAMS:-4}"
GUARD_CONNECTIONS="${ETA_H2_ECHO_1X16_CONNECTIONS:-1}"
GUARD_STREAMS="${ETA_H2_ECHO_1X16_STREAMS:-16}"
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
  local shape="$2"
  local endpoint="$3"
  local method="$4"
  local path="$5"
  local body_file="$6"
  local requests="$7"
  local repeat="$8"
  local port="$9"
  local connections="${10}"
  local streams="${11}"
  local raw="$RESULT_DIR/${shape}-${mode}-${endpoint}-${repeat}.json"
  local err="$RESULT_DIR/${shape}-${mode}-${endpoint}-${repeat}.err"
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
    -c "$connections"
    -p "$streams"
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

run_4x4_endpoint_set() {
  local mode="$1"
  local port="$2"
  for repeat in $(seq 1 "$REPEATS"); do
    echo "$mode 4x4 repeat $repeat/$REPEATS: H2 root/user/post/static/echo" >&2
    run_oha "$mode" 4x4 root GET / "" "$REQUESTS" "$repeat" "$port" \
      "$PRIMARY_CONNECTIONS" "$PRIMARY_STREAMS"
    run_oha "$mode" 4x4 user_id GET /user/123 "" "$REQUESTS" "$repeat" "$port" \
      "$PRIMARY_CONNECTIONS" "$PRIMARY_STREAMS"
    run_oha "$mode" 4x4 post POST /user "" "$REQUESTS" "$repeat" "$port" \
      "$PRIMARY_CONNECTIONS" "$PRIMARY_STREAMS"
    run_oha "$mode" 4x4 static GET /static/1k.bin "" "$REQUESTS" "$repeat" "$port" \
      "$PRIMARY_CONNECTIONS" "$PRIMARY_STREAMS"
    run_oha "$mode" 4x4 echo POST /echo "$BODY_1K" "$REQUESTS" "$repeat" "$port" \
      "$PRIMARY_CONNECTIONS" "$PRIMARY_STREAMS"
  done
}

run_plain_1x16_echo_guard() {
  local port="$1"
  for repeat in $(seq 1 "$REPEATS"); do
    echo "plain 1x16 repeat $repeat/$REPEATS: H2 echo" >&2
    run_oha plain 1x16 echo POST /echo "$BODY_1K" "$REQUESTS" "$repeat" "$port" \
      "$GUARD_CONNECTIONS" "$GUARD_STREAMS"
  done
}

PLAIN_PORT="$(start_server plain)"
run_4x4_endpoint_set plain "$PLAIN_PORT"
run_plain_1x16_echo_guard "$PLAIN_PORT"
cleanup_server

TLS_PORT="$(start_server tls)"
run_4x4_endpoint_set tls "$TLS_PORT"
cleanup_server

python - "$RESULT_DIR" "$REQUESTS" "$REPEATS" <<'PY'
import csv
import json
import math
import statistics
import sys
from pathlib import Path

result_dir = Path(sys.argv[1])
requests = int(sys.argv[2])
repeats = int(sys.argv[3])

endpoints_4x4 = [
    ("root", 0),
    ("user_id", 3),
    ("post", 0),
    ("static", 1024),
    ("echo", 1024),
]

cases = []
for mode in ["plain", "tls"]:
    for repeat in range(1, repeats + 1):
        for endpoint, expected_body_bytes in endpoints_4x4:
            cases.append(
                {
                    "shape": "4x4",
                    "mode": mode,
                    "endpoint": endpoint,
                    "expected_body_bytes": expected_body_bytes,
                    "requests": requests,
                    "repeat": repeat,
                }
            )
for repeat in range(1, repeats + 1):
    cases.append(
        {
            "shape": "1x16",
            "mode": "plain",
            "endpoint": "echo",
            "expected_body_bytes": 1024,
            "requests": requests,
            "repeat": repeat,
        }
    )

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

def read_case(case):
    raw_path = result_dir / (
        f"{case['shape']}-{case['mode']}-{case['endpoint']}-{case['repeat']}.json"
    )
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
    expected_total_data = case["requests"] * case["expected_body_bytes"]
    endpoint_success = (
        ok_count == case["requests"]
        and total_requests == case["requests"]
        and errors == 0
        and number(summary.get("successRate")) == 1.0
        and total_data == expected_total_data
    )
    return {
        "shape": case["shape"],
        "mode": case["mode"],
        "endpoint": case["endpoint"],
        "repeat": case["repeat"],
        "success": 1 if endpoint_success else 0,
        "requests": case["requests"],
        "rps": number(summary.get("requestsPerSec")),
        "p50_us": number(latency.get("p50")) * 1_000_000.0,
        "p95_us": number(latency.get("p95")) * 1_000_000.0,
        "p99_us": number(latency.get("p99")) * 1_000_000.0,
        "p999_us": number(latency.get("p99.9")) * 1_000_000.0,
        "max_us": number(summary.get("slowest")) * 1_000_000.0,
        "total_data": total_data,
    }

rows = [read_case(case) for case in cases]
summary_path = result_dir / "h2-echo-4x4-summary.tsv"
with summary_path.open("w", newline="") as f:
    fieldnames = [
        "shape",
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
metrics = {
    "h2_echo_4x4_success": 1.0 if success else 0.0,
}

print("shape\tmode\tendpoint\tp50_us\tp95_us\tp99_us\tp999_us\tmax_us\trps\trepeats")
for shape in ["4x4", "1x16"]:
    for mode in ["plain", "tls"]:
        mode_shape_rows = [
            row for row in rows if row["shape"] == shape and row["mode"] == mode
        ]
        if not mode_shape_rows:
            continue
        endpoints = sorted({row["endpoint"] for row in mode_shape_rows})
        if shape == "4x4":
            repeat_geomeans = []
            for repeat in range(1, repeats + 1):
                repeat_rows = [
                    row for row in mode_shape_rows if row["repeat"] == repeat
                ]
                repeat_geomeans.append(geomean([row["rps"] for row in repeat_rows]))
            metrics[f"h2_{mode}_4x4_rps_geomean"] = median(repeat_geomeans)

        for endpoint in endpoints:
            endpoint_rows = [row for row in mode_shape_rows if row["endpoint"] == endpoint]
            p99s = [row["p99_us"] for row in endpoint_rows]
            repeat_text = ",".join(f"{value:.0f}" for value in p99s)
            prefix = f"h2_{mode}_{endpoint}_{shape}"
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
                f"{shape}\t{mode}\t{endpoint}\t"
                f"{metrics[f'{prefix}_p50_us']:.0f}\t"
                f"{metrics[f'{prefix}_p95_us']:.0f}\t"
                f"{metrics[f'{prefix}_p99_us']:.0f}\t"
                f"{metrics[f'{prefix}_p999_us']:.0f}\t"
                f"{metrics[f'{prefix}_max_us']:.0f}\t"
                f"{metrics[f'{prefix}_rps']:.0f}\t"
                f"{repeat_text}"
            )

echo_4x4_geomeans = []
for repeat in range(1, repeats + 1):
    echo_rows = [
        row
        for row in rows
        if row["shape"] == "4x4" and row["endpoint"] == "echo" and row["repeat"] == repeat
    ]
    echo_4x4_geomeans.append(geomean([row["rps"] for row in echo_rows]))
metrics["h2_echo_4x4_rps_geomean"] = median(echo_4x4_geomeans)

plain_echo_4x4 = metrics["h2_plain_echo_4x4_p99_us"]
plain_echo_1x16 = metrics["h2_plain_echo_1x16_p99_us"]
metrics["h2_plain_echo_4x4_to_1x16_p99_ratio"] = (
    plain_echo_4x4 / plain_echo_1x16 if plain_echo_1x16 > 0 else 0.0
)

for name, value in metrics.items():
    print(f"METRIC {name}={value:.6f}")
print(f"h2 echo 4x4 summary: {summary_path}", file=sys.stderr)
PY
