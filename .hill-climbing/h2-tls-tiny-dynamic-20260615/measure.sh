#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"
REQUESTS="${ETA_H2_TLS_TINY_REQUESTS:-24000}"
REPEATS="${ETA_H2_TLS_TINY_REPEATS:-9}"
TIMEOUT="${ETA_H2_TLS_TINY_TIMEOUT:-10s}"
CONNECTIONS="${ETA_H2_TLS_TINY_CONNECTIONS:-1}"
STREAMS="${ETA_H2_TLS_TINY_STREAMS:-16}"
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

echo "building H2 TLS probe" >&2
nix develop -c dune build http-testsuite/test/server_load/h2_tls_probe.exe

BODY_1K="$TMP_DIR/body-echo-1k.bin"
python - "$BODY_1K" <<'PY'
import sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(b"x" * 1024)
PY

PORT=$((18000 + RANDOM % 20000))
SERVER_TMP="$TMP_DIR/server"
SERVER_LOG="$RESULT_DIR/server.log"
mkdir -p "$SERVER_TMP"

SERVER_CORE="${ETA_SERVER_LOAD_SERVER_CORE:-2}"
LOAD_CORE="${ETA_SERVER_LOAD_LOAD_CORE:-3}"

echo "starting Eta H2 TLS probe on port $PORT" >&2
server_cmd=(_build/default/http-testsuite/test/server_load/h2_tls_probe.exe)
if bool_env ETA_SERVER_LOAD_PIN true && have_command taskset; then
  server_cmd=(taskset -c "$SERVER_CORE" "${server_cmd[@]}")
fi
"${server_cmd[@]}" "$PORT" "$SERVER_TMP" >"$SERVER_LOG" 2>&1 &
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

run_oha() {
  local endpoint="$1"
  local method="$2"
  local path="$3"
  local body_file="$4"
  local repeat="$5"
  local raw="$RESULT_DIR/${endpoint}-${repeat}.json"
  local err="$RESULT_DIR/${endpoint}-${repeat}.err"
  local url="https://127.0.0.1:${PORT}${path}"
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
    -n "$REQUESTS"
    --http-version 2
    --insecure
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

for repeat in $(seq 1 "$REPEATS"); do
  echo "repeat $repeat/$REPEATS: root/user/post/static/echo H2 TLS 1x16" >&2
  run_oha root GET / "" "$repeat"
  run_oha user_id GET /user/123 "" "$repeat"
  run_oha post_user POST /user "" "$repeat"
  run_oha static_1k GET /static/1k.bin "" "$repeat"
  run_oha echo_1k POST /echo "$BODY_1K" "$repeat"
done

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

def pct(values, p):
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil((p / 100.0) * len(ordered)) - 1))
    return ordered[index]

def median(values):
    return statistics.median(values)

def geomean(values):
    if any(value <= 0 for value in values):
        return 0.0
    return math.exp(sum(math.log(value) for value in values) / len(values))

rows = []
success = True

for repeat in range(1, repeats + 1):
    for endpoint, expected_body_bytes in endpoints:
        raw_path = result_dir / f"{endpoint}-{repeat}.json"
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
        success = success and endpoint_success
        rows.append(
            {
                "repeat": repeat,
                "endpoint": endpoint,
                "success": 1 if endpoint_success else 0,
                "rps": number(summary.get("requestsPerSec")),
                "p50_us": number(latency.get("p50")) * 1_000_000.0,
                "p95_us": number(latency.get("p95")) * 1_000_000.0,
                "p99_us": number(latency.get("p99")) * 1_000_000.0,
                "p999_us": number(latency.get("p99.9")) * 1_000_000.0,
                "max_us": number(summary.get("slowest")) * 1_000_000.0,
                "total_data": total_data,
            }
        )

summary_path = result_dir / "h2-tls-tiny-summary.tsv"
with summary_path.open("w", newline="") as f:
    fieldnames = [
        "repeat",
        "endpoint",
        "success",
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

by_endpoint = {endpoint: [] for endpoint, _ in endpoints}
for row in rows:
    by_endpoint[row["endpoint"]].append(row)

repeat_geomeans = []
for repeat in range(1, repeats + 1):
    repeat_rows = [row for row in rows if row["repeat"] == repeat]
    repeat_geomeans.append(geomean([row["rps"] for row in repeat_rows]))

print("endpoint\tp50_us\tp95_us\tp99_us\tp999_us\tmax_us\trps\trepeats")
for endpoint, _ in endpoints:
    endpoint_rows = by_endpoint[endpoint]
    p99s = [row["p99_us"] for row in endpoint_rows]
    repeat_text = ",".join(f"{value:.0f}" for value in p99s)
    print(
        f"{endpoint}\t"
        f"{median([row['p50_us'] for row in endpoint_rows]):.0f}\t"
        f"{median([row['p95_us'] for row in endpoint_rows]):.0f}\t"
        f"{median(p99s):.0f}\t"
        f"{median([row['p999_us'] for row in endpoint_rows]):.0f}\t"
        f"{max(row['max_us'] for row in endpoint_rows):.0f}\t"
        f"{median([row['rps'] for row in endpoint_rows]):.0f}\t"
        f"{repeat_text}"
    )

metrics = {
    "h2_tls_success": 1.0 if success else 0.0,
    "h2_tls_rps_geomean": median(repeat_geomeans),
}
for endpoint, _ in endpoints:
    endpoint_rows = by_endpoint[endpoint]
    metrics[f"h2_tls_{endpoint}_p50_us"] = median(
        [row["p50_us"] for row in endpoint_rows]
    )
    metrics[f"h2_tls_{endpoint}_p95_us"] = median(
        [row["p95_us"] for row in endpoint_rows]
    )
    metrics[f"h2_tls_{endpoint}_p99_us"] = median(
        [row["p99_us"] for row in endpoint_rows]
    )
    metrics[f"h2_tls_{endpoint}_p999_us"] = median(
        [row["p999_us"] for row in endpoint_rows]
    )
    metrics[f"h2_tls_{endpoint}_max_us"] = max(
        [row["max_us"] for row in endpoint_rows]
    )
    metrics[f"h2_tls_{endpoint}_rps"] = median(
        [row["rps"] for row in endpoint_rows]
    )

for name, value in metrics.items():
    print(f"METRIC {name}={value:.6f}")
print(f"h2 tls tiny summary: {summary_path}", file=sys.stderr)
PY
