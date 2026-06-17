#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H1_TLS_ECHO_REQUESTS:-24000}"
REPEATS="${ETA_H1_TLS_ECHO_REPEATS:-9}"
CONCURRENCY="${ETA_H1_TLS_ECHO_CONCURRENCY:-16}"
TIMEOUT="${ETA_H1_TLS_ECHO_TIMEOUT:-10s}"
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

echo "building H1 probes" >&2
nix develop -c dune build \
  http-testsuite/test/server_load/h1_probe.exe \
  http-testsuite/test/server_load/h1_tls_probe.exe

BODY_1K="$TMP_DIR/body-echo-1k.bin"
python -c 'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b"x" * 1024)' "$BODY_1K"

SERVER_CORE="${ETA_SERVER_LOAD_SERVER_CORE:-2}"
LOAD_CORE="${ETA_SERVER_LOAD_LOAD_CORE:-3}"

start_server() {
  local mode="$1"
  cleanup_server
  local port=$((18000 + RANDOM % 20000))
  local server_tmp="$TMP_DIR/server-$mode"
  local server_log="$RESULT_DIR/server-$mode.log"
  mkdir -p "$server_tmp"

  local probe="_build/default/http-testsuite/test/server_load/h1_probe.exe"
  if [[ "$mode" == "tls" ]]; then
    probe="_build/default/http-testsuite/test/server_load/h1_tls_probe.exe"
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
  local endpoint="$2"
  local method="$3"
  local path="$4"
  local body_file="$5"
  local repeat="$6"
  local port="$7"
  local raw="$RESULT_DIR/${mode}-${endpoint}-${repeat}.json"
  local err="$RESULT_DIR/${mode}-${endpoint}-${repeat}.err"
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
    -c "$CONCURRENCY"
    -n "$REQUESTS"
    --http-version 1.1
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
  local port="$2"
  for repeat in $(seq 1 "$REPEATS"); do
    echo "$mode repeat $repeat/$REPEATS: H1 root/user/post/static/echo" >&2
    run_oha "$mode" root GET / "" "$repeat" "$port"
    run_oha "$mode" user_id GET /user/123 "" "$repeat" "$port"
    run_oha "$mode" post_user POST /user "" "$repeat" "$port"
    run_oha "$mode" static_1k GET /static/1k.bin "" "$repeat" "$port"
    run_oha "$mode" echo_1k POST /echo "$BODY_1K" "$repeat" "$port"
  done
}

PLAIN_PORT="$(start_server plain)"
run_endpoint_set plain "$PLAIN_PORT"
cleanup_server

TLS_PORT="$(start_server tls)"
run_endpoint_set tls "$TLS_PORT"
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

endpoints = [
    ("root", 0),
    ("user_id", 3),
    ("post_user", 0),
    ("static_1k", 1024),
    ("echo_1k", 1024),
]

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

def read_case(mode, endpoint, expected_body_bytes, repeat):
    raw_path = result_dir / f"{mode}-{endpoint}-{repeat}.json"
    with raw_path.open() as f:
        raw = json.load(f)
    summary = raw.get("summary", {})
    latency = raw.get("latencyPercentiles", {})
    errors = int(summary.get("errorDistribution", {}).get("total", 0) or 0)
    status_dist = raw.get("statusCodeDistribution", {})
    total = int(summary.get("totalRequests", requests) or requests)
    status_200 = int(status_dist.get("200", 0) or 0)
    total_data = int(number(summary.get("totalData")))
    expected_total_data = expected_body_bytes * requests
    success_rate = number(summary.get("successRate"))
    ok = (
        total == requests
        and status_200 == requests
        and errors == 0
        and success_rate == 1.0
        and total_data == expected_total_data
    )
    return {
        "mode": mode,
        "endpoint": endpoint,
        "repeat": repeat,
        "ok": ok,
        "p50_us": number(latency.get("p50")) * 1_000_000.0,
        "p95_us": number(latency.get("p95")) * 1_000_000.0,
        "p99_us": number(latency.get("p99")) * 1_000_000.0,
        "p999_us": number(latency.get("p99.9")) * 1_000_000.0,
        "max_us": number(summary.get("slowest")) * 1_000_000.0,
        "rps": number(summary.get("requestsPerSec")),
        "total_data": total_data,
    }

rows = []
for mode in ["plain", "tls"]:
    for repeat in range(1, repeats + 1):
        for endpoint, expected_body_bytes in endpoints:
            rows.append(read_case(mode, endpoint, expected_body_bytes, repeat))

metrics = {}
success = 1.0 if all(row["ok"] for row in rows) else 0.0
metrics["h1_echo_1k_success"] = success

summary_rows = []
for mode in ["plain", "tls"]:
    mode_rps = []
    for endpoint, _ in endpoints:
        case_rows = [
            row for row in rows if row["mode"] == mode and row["endpoint"] == endpoint
        ]
        prefix = f"h1_{mode}_{endpoint}"
        for name in ["p50_us", "p95_us", "p99_us", "p999_us", "max_us", "rps"]:
            values = [row[name] for row in case_rows]
            metrics[f"{prefix}_{name}"] = median(values)
        mode_rps.extend(row["rps"] for row in case_rows)
        summary_rows.append(
            {
                "mode": mode,
                "endpoint": endpoint,
                "p50_us": metrics[f"{prefix}_p50_us"],
                "p95_us": metrics[f"{prefix}_p95_us"],
                "p99_us": metrics[f"{prefix}_p99_us"],
                "p999_us": metrics[f"{prefix}_p999_us"],
                "max_us": metrics[f"{prefix}_max_us"],
                "rps": metrics[f"{prefix}_rps"],
                "repeat_p99_us": ",".join(f"{row['p99_us']:.3f}" for row in case_rows),
            }
        )
    metrics[f"h1_{mode}_rps_geomean"] = geomean(mode_rps)

metrics["h1_echo_1k_rps_geomean"] = geomean(
    [
        metrics["h1_plain_echo_1k_rps"],
        metrics["h1_tls_echo_1k_rps"],
    ]
)
metrics["h1_tls_echo_1k_to_plain_p99_ratio"] = (
    metrics["h1_tls_echo_1k_p99_us"] / metrics["h1_plain_echo_1k_p99_us"]
    if metrics["h1_plain_echo_1k_p99_us"] > 0
    else 0.0
)

summary_path = result_dir / "h1-tls-echo-summary.tsv"
with summary_path.open("w", newline="") as f:
    writer = csv.DictWriter(
        f,
        fieldnames=[
            "mode",
            "endpoint",
            "p50_us",
            "p95_us",
            "p99_us",
            "p999_us",
            "max_us",
            "rps",
            "repeat_p99_us",
        ],
        delimiter="\t",
    )
    writer.writeheader()
    writer.writerows(summary_rows)

print(f"h1 tls echo summary: {summary_path}", file=sys.stderr)
for name in sorted(metrics):
    print(f"METRIC {name}={metrics[name]:.6f}")
PY
