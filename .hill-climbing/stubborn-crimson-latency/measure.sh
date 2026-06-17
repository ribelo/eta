#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

if [ "${ETA_HILL_IN_NIX:-0}" != "1" ]; then
  export ETA_HILL_IN_NIX=1
  exec nix develop -c bash "$0"
fi

export EIO_BACKEND="${EIO_BACKEND:-posix}"

EXE="_build/default/http-testsuite/test/server_load/h1_tls_probe.exe"
BASE_REQUESTS="${ETA_H1TLS_REQUESTS:-1000}"
CONNECTIONS="${ETA_H1TLS_CONNECTIONS:-16}"
REPS="${ETA_H1TLS_REPS:-3}"
TIMEOUT="${ETA_H1TLS_TIMEOUT:-5s}"
MIN_REQUESTS_PER_CONNECTION_FOR_P99="${ETA_H1TLS_MIN_REQUESTS_PER_CONNECTION_FOR_P99:-200}"

if [ "$BASE_REQUESTS" -ge 1000 ]; then
  REQUESTS="$(( BASE_REQUESTS > CONNECTIONS * MIN_REQUESTS_PER_CONNECTION_FOR_P99 ? BASE_REQUESTS : CONNECTIONS * MIN_REQUESTS_PER_CONNECTION_FOR_P99 ))"
else
  REQUESTS="$BASE_REQUESTS"
fi

dune build --profile release http-testsuite/test/server_load/h1_tls_probe.exe

PORT="$(python3 - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)"
TMP="$(mktemp -d)"
LOG="$TMP/probe.log"
SAMPLES="$TMP/samples.tsv"
touch "$SAMPLES"

SERVER_CMD=()
OHA_CMD=()
if [ "${ETA_SERVER_LOAD_PIN:-1}" != "0" ] && command -v taskset >/dev/null 2>&1; then
  SERVER_CMD=(taskset -c "${ETA_SERVER_LOAD_SERVER_CORE:-2}")
  OHA_CMD=(taskset -c "${ETA_SERVER_LOAD_LOAD_CORE:-3}")
fi

cleanup() {
  if [ "${PID:-}" != "" ]; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

"${SERVER_CMD[@]}" "$EXE" "$PORT" "$TMP" >"$LOG" 2>&1 &
PID=$!

for _ in $(seq 1 200); do
  if [ "$(curl -sk --http1.1 -o /dev/null -w "%{http_code}" "https://127.0.0.1:$PORT/healthz" 2>/dev/null || true)" = "200" ]; then
    break
  fi
  sleep 0.05
done

if [ "$(curl -sk --http1.1 -o /dev/null -w "%{http_code}" "https://127.0.0.1:$PORT/healthz" 2>/dev/null || true)" != "200" ]; then
  echo "probe did not become ready" >&2
  cat "$LOG" >&2
  exit 1
fi

run_oha() {
  local endpoint="$1"
  local method="$2"
  local path="$3"
  local body_bytes="$4"
  local repeat="$5"
  local out="$TMP/$endpoint-$repeat.json"
  local flags=()

  if [ "$method" = "POST" ]; then
    flags+=(-m POST -T text/plain)
    if [ "$body_bytes" -gt 0 ]; then
      flags+=(-D "$TMP/body-$endpoint-$body_bytes.bin")
    fi
  fi

  if [ "$body_bytes" -gt 0 ]; then
    python3 - "$TMP/body-$endpoint-$body_bytes.bin" "$body_bytes" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
size = int(sys.argv[2])
if not path.exists() or path.stat().st_size != size:
    path.write_bytes(b"x" * size)
PY
  fi

  NO_COLOR=false "${OHA_CMD[@]}" oha --no-tui --output-format json --redirect 0 \
    --disable-compression --connect-timeout 2s -t "$TIMEOUT" \
    -c "$CONNECTIONS" -n "$REQUESTS" --http-version 1.1 --insecure \
    "${flags[@]}" "https://127.0.0.1:$PORT$path" >"$out"

  python3 - "$endpoint" "$out" "$REQUESTS" <<'PY' >>"$SAMPLES"
import json
import sys

endpoint, path, expected = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

summary = data["summary"]
latency = data["latencyPercentiles"]
status_dist = data.get("statusCodeDistribution") or {}
error_dist = data.get("errorDistribution") or {}
total = sum(int(v) for v in status_dist.values())
errors = sum(int(v) for v in error_dist.values())
ok = (
    float(summary.get("successRate", 0.0)) == 1.0
    and errors == 0
    and total == expected
    and int(status_dist.get("200", 0)) == expected
)

print(
    endpoint,
    float(summary["requestsPerSec"]),
    float(latency["p50"]) * 1000.0,
    float(latency["p99"]) * 1000.0,
    1 if ok else 0,
    sep="\t",
)
PY
}

for repeat in $(seq 1 "$REPS"); do
  run_oha root GET / 0 "$repeat"
  run_oha user_id GET /user/123 0 "$repeat"
  run_oha post_user POST /user 0 "$repeat"
  run_oha static_1k GET /static/1k.bin 0 "$repeat"
  run_oha echo_1k POST /echo 1024 "$repeat"
done

python3 - "$SAMPLES" <<'PY'
import math
import statistics
import sys
from collections import defaultdict

samples = defaultdict(lambda: {"rps": [], "p50": [], "p99": [], "ok": []})
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for line in f:
        endpoint, rps, p50, p99, ok = line.rstrip("\n").split("\t")
        samples[endpoint]["rps"].append(float(rps))
        samples[endpoint]["p50"].append(float(p50))
        samples[endpoint]["p99"].append(float(p99))
        samples[endpoint]["ok"].append(int(ok))

endpoints = ["root", "user_id", "post_user", "static_1k", "echo_1k"]
all_ok = 1
rps_values = []
p99_values = []

for endpoint in endpoints:
    current = samples[endpoint]
    rps = statistics.median(current["rps"])
    p50 = statistics.median(current["p50"])
    p99 = statistics.median(current["p99"])
    ok = 1 if current["ok"] and all(v == 1 for v in current["ok"]) else 0
    all_ok = all_ok and ok
    rps_values.append(rps)
    p99_values.append(p99)
    print(f"RESULT {endpoint} rps={rps:.0f} p50_ms={p50:.3f} p99_ms={p99:.3f} ok={ok}")
    print(f"METRIC h1_tls_{endpoint}_rps={rps:.0f}")
    print(f"METRIC h1_tls_{endpoint}_p50_ms={p50:.6f}")
    print(f"METRIC h1_tls_{endpoint}_p99_ms={p99:.6f}")

if all_ok and all(v > 0.0 for v in rps_values + p99_values):
    rps_geomean = math.exp(sum(math.log(v) for v in rps_values) / len(rps_values))
    p99_geomean = math.exp(sum(math.log(v) for v in p99_values) / len(p99_values))
    print(f"METRIC h1_tls_rps_geomean={rps_geomean:.0f}")
    print(f"METRIC h1_tls_p99_ms_geomean={p99_geomean:.6f}")
    print("METRIC success=1")
else:
    print("METRIC h1_tls_rps_geomean=0")
    print("METRIC h1_tls_p99_ms_geomean=0")
    print("METRIC success=0")
PY
