#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

if [ "${ETA_HILL_IN_NIX:-0}" != "1" ]; then
  export ETA_HILL_IN_NIX=1
  exec nix develop -c bash "$0"
fi

export EIO_BACKEND="${EIO_BACKEND:-posix}"

EXE="_build/default/http-testsuite/test/server_load/h2_probe.exe"
CONNECTIONS="${ETA_H2PLAIN_CONNECTIONS:-1}"
STREAMS_PER_CONNECTION="${ETA_H2PLAIN_STREAMS_PER_CONNECTION:-16}"
REQUESTS="${ETA_H2PLAIN_REQUESTS:-24000}"
REPS="${ETA_H2PLAIN_REPS:-9}"
TIMEOUT="${ETA_H2PLAIN_TIMEOUT:-5s}"
WARMUP_REQUESTS="${ETA_H2PLAIN_WARMUP_REQUESTS:-3000}"

dune build --profile release http-testsuite/test/server_load/h2_probe.exe

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
BODY="$TMP/body-echo_1k-1024.bin"
touch "$SAMPLES"
python3 - "$BODY" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.write_bytes(b"x" * 1024)
PY

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
  grep -q READY "$LOG" && break
  sleep 0.05
done
if ! grep -q READY "$LOG"; then
  echo "probe did not become ready" >&2
  cat "$LOG" >&2
  exit 1
fi

run_oha() {
  local method="$1"
  local path="$2"
  local body_path="${3:-}"
  local requests="$4"
  local out="$5"
  local flags=()

  if [ "$method" = "POST" ]; then
    flags+=(-m POST -T text/plain)
    if [ "$body_path" != "" ]; then
      flags+=(-D "$body_path")
    fi
  fi

  NO_COLOR=false "${OHA_CMD[@]}" oha --no-tui --output-format json \
    --redirect 0 --disable-compression --connect-timeout 2s -t "$TIMEOUT" \
    -c "$CONNECTIONS" -p "$STREAMS_PER_CONNECTION" -n "$requests" \
    --http-version 2 "${flags[@]}" "http://127.0.0.1:$PORT$path" >"$out"
}

record_sample() {
  local endpoint="$1"
  local out="$2"
  local expected="$3"
  python3 - "$endpoint" "$out" "$expected" <<'PY' >>"$SAMPLES"
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
    float(latency["p90"]) * 1000.0,
    float(latency["p95"]) * 1000.0,
    float(latency["p99"]) * 1000.0,
    float(summary["slowest"]) * 1000.0,
    1 if ok else 0,
    sep="\t",
)
PY
}

run_oha POST /echo "$BODY" "$WARMUP_REQUESTS" "$TMP/warmup.json"

for repeat in $(seq 1 "$REPS"); do
  run_oha POST /echo "$BODY" "$REQUESTS" "$TMP/echo_1k-$repeat.json"
  record_sample echo_1k "$TMP/echo_1k-$repeat.json" "$REQUESTS"

  run_oha GET / "" "$REQUESTS" "$TMP/root-$repeat.json"
  record_sample root "$TMP/root-$repeat.json" "$REQUESTS"

  run_oha POST /user "" "$REQUESTS" "$TMP/post_user-$repeat.json"
  record_sample post_user "$TMP/post_user-$repeat.json" "$REQUESTS"

  run_oha GET /static/1k.bin "" "$REQUESTS" "$TMP/static_1k-$repeat.json"
  record_sample static_1k "$TMP/static_1k-$repeat.json" "$REQUESTS"
done

python3 - "$SAMPLES" <<'PY'
import math
import statistics
import sys
from collections import defaultdict

samples = defaultdict(lambda: {
    "rps": [], "p50": [], "p90": [], "p95": [], "p99": [], "max": [], "ok": []
})
with open(sys.argv[1], "r", encoding="utf-8") as f:
    for line in f:
        endpoint, rps, p50, p90, p95, p99, max_, ok = line.rstrip("\n").split("\t")
        current = samples[endpoint]
        current["rps"].append(float(rps))
        current["p50"].append(float(p50))
        current["p90"].append(float(p90))
        current["p95"].append(float(p95))
        current["p99"].append(float(p99))
        current["max"].append(float(max_))
        current["ok"].append(int(ok))

endpoints = ["echo_1k", "root", "post_user", "static_1k"]
all_ok = 1
p99_values = []
rps_values = []

def median(values):
    return statistics.median(values)

def mad(values):
    center = median(values)
    return median([abs(value - center) for value in values])

for endpoint in endpoints:
    current = samples[endpoint]
    ok = 1 if current["ok"] and all(v == 1 for v in current["ok"]) else 0
    all_ok = all_ok and ok
    rps = median(current["rps"])
    p50 = median(current["p50"])
    p90 = median(current["p90"])
    p95 = median(current["p95"])
    p99 = median(current["p99"])
    max_ = median(current["max"])
    p99_min = min(current["p99"])
    p99_max = max(current["p99"])
    p99_mad = mad(current["p99"])
    p99_values.append(p99)
    rps_values.append(rps)
    repeats = ",".join(f"{value:.3f}" for value in current["p99"])
    print(
        f"RESULT {endpoint} rps={rps:.0f} p50_ms={p50:.3f} "
        f"p95_ms={p95:.3f} p99_ms={p99:.3f} p99_mad_ms={p99_mad:.3f} "
        f"p99_repeats={repeats} ok={ok}"
    )
    print(f"METRIC h2_plain_{endpoint}_rps={rps:.0f}")
    print(f"METRIC h2_plain_{endpoint}_p50_ms={p50:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p90_ms={p90:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p95_ms={p95:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p99_ms={p99:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p99_min_ms={p99_min:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p99_max_ms={p99_max:.6f}")
    print(f"METRIC h2_plain_{endpoint}_p99_mad_ms={p99_mad:.6f}")
    print(f"METRIC h2_plain_{endpoint}_max_ms={max_:.6f}")

if all_ok and all(v > 0.0 for v in p99_values + rps_values):
    p99_geomean = math.exp(sum(math.log(v) for v in p99_values) / len(p99_values))
    rps_geomean = math.exp(sum(math.log(v) for v in rps_values) / len(rps_values))
    print(f"METRIC h2_plain_p99_ms_geomean={p99_geomean:.6f}")
    print(f"METRIC h2_plain_rps_geomean={rps_geomean:.0f}")
    print("METRIC success=1")
else:
    print("METRIC h2_plain_p99_ms_geomean=0")
    print("METRIC h2_plain_rps_geomean=0")
    print("METRIC success=0")
PY
