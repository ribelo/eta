#!/usr/bin/env bash
# Autoresearch benchmark: Eta HTTP/1.1 server TAIL LATENCY over REAL sockets.
#
# Context: the H2 latency session took H2 p99 from 4639->2540us geomean (-45%)
# by removing per-op Eio timeout forks and deferring OTEL attribute building.
# The server-load comparison then showed H1 Eta is the weakest spot vs Go:
# H1 Eta/Go = 0.81x RPS, 1.55x p99 (worst tail in the suite). The H1 server
# (h1_server_connection.ml) still has the SAME anti-patterns the H2 session
# eliminated: per-op with_timeout/Fiber.first on write/body/handler/head reads,
# and request_metrics gated only on enable_otel (not metrics_enabled).
#
# Drives a standalone Eta H1 server (h1_probe.exe) with oha over HTTP/1.1.
# Keeps the same 4 endpoints + median-of-3 methodology as the H2 session so the
# numbers are directly comparable; only the protocol and concurrency model
# differ (H1 has no multiplexing, so concurrency = number of connections).
#
# Emits `METRIC name=value` lines on stdout.
#
# Primary metric: h1_p99_us_geomean (microseconds, LOWER is better) - geomean of
# per-endpoint p99 latency. Secondary monitors: per-endpoint p99/p50, rps geomean
# (throughput must not regress), server peak RSS (memory), success.
set -euo pipefail

cd "$(dirname "$0")/.."
export EIO_BACKEND="${EIO_BACKEND:-posix}"

EXE=_build/default/http-testsuite/test/server_load/h1_probe.exe

# Release build: we optimize the shipping artifact.
nix develop -c dune build --profile release \
  http-testsuite/test/server_load/h1_probe.exe 2>&1 | tail -20

# CPU pinning to cut scheduler/migration noise: server on core 2, load gen core 3.
SRV_PIN=""
OHA_PIN=""
if command -v taskset >/dev/null 2>&1; then
  SRV_PIN="taskset -c 2"
  OHA_PIN="taskset -c 3"
fi

# Load shape: 16 concurrent keep-alive connections (H1 has no stream
# multiplexing, so concurrency == connection count). Matches the effective
# concurrency of the H2 session for comparability.
N="${ETA_H1_REQUESTS:-40000}"
C=16
REPS="${ETA_H1_REPS:-3}"

run_bench() {
  nix develop -c bash -c '
    set -euo pipefail
    export EIO_BACKEND="'"$EIO_BACKEND"'"
    PORT=$(shuf -i 20000-60000 -n1)
    TMP=$(mktemp -d)
    LOG=$(mktemp)
    '"$SRV_PIN"' '"$EXE"' "$PORT" "$TMP" >"$LOG" 2>&1 &
    PID=$!
    PEAK_RSS=0
    cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -rf "$TMP" "$LOG"; }
    trap cleanup EXIT
    # Wait for READY (server bound + listening).
    for _ in $(seq 1 100); do
      grep -q READY "$LOG" && break
      sleep 0.05
    done
    grep -q READY "$LOG" || { echo "PROBE_FAILED"; cat "$LOG"; exit 1; }

    # Emit "rps p99_us p50_us successRate" for one oha run.
    sample() {
      '"$OHA_PIN"' oha --no-tui --output-format json --http-version 1.1 \
        --redirect 0 --disable-compression -c '"$C"' -n '"$N"' "$1" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); s=d[\"summary\"]; lp=d[\"latencyPercentiles\"]; print(\"%.0f %.2f %.2f %.4f\" % (s[\"requestsPerSec\"], lp[\"p99\"]*1e6, lp[\"p50\"]*1e6, s[\"successRate\"]))"
    }

    declare -A BASE=(
      [root]="http://127.0.0.1:$PORT/"
      [user_id]="http://127.0.0.1:$PORT/user/123"
      [static_1k]="http://127.0.0.1:$PORT/static/1k.bin"
      [echo_1k]="http://127.0.0.1:$PORT/echo"
    )
    # Warmup (prime oha connections + server steady state).
    sample "${BASE[root]}" >/dev/null

    median() { printf "%s\n" "$@" | sort -n | awk "{a[NR]=\$1} END{print a[int((NR+1)/2)]}"; }

    for ep in root user_id static_1k echo_1k; do
      url="${BASE[$ep]}"
      rps_v=(); p99_v=(); p50_v=(); ok=1
      for _ in $(seq 1 '"$REPS"'); do
        read -r r p99 p50 sr <<<"$(sample "$url")"
        rps_v+=("$r"); p99_v+=("$p99"); p50_v+=("$p50")
        awk "BEGIN{exit !($sr < 0.999)}" && ok=0
        if [ -r "/proc/$PID/status" ]; then
          hwm=$(awk "/VmHWM/{print \$2}" "/proc/$PID/status")
          [ -n "$hwm" ] && [ "$hwm" -gt "$PEAK_RSS" ] && PEAK_RSS=$hwm
        fi
      done
      echo "RESULT $ep rps=$(median "${rps_v[@]}") p99=$(median "${p99_v[@]}") p50=$(median "${p50_v[@]}") ok=$ok"
    done
    echo "RESULT_MEM rss_kb=$PEAK_RSS"
  '
}

OUT=$(run_bench)
echo "$OUT" | grep -vE "^RESULT" || true

declare -A RPS P99 P50
ALL_OK=1
RSS_KB=0
while read -r line; do
  case "$line" in
    "RESULT_MEM "*)
      RSS_KB=$(echo "$line" | sed -E 's/.*rss_kb=([0-9]+).*/\1/')
      ;;
    "RESULT "*)
      ep=$(echo "$line" | awk '{print $2}')
      r=$(echo  "$line" | sed -E 's/.* rps=([0-9.]+).*/\1/')
      p99=$(echo "$line" | sed -E 's/.* p99=([0-9.]+).*/\1/')
      p50=$(echo "$line" | sed -E 's/.* p50=([0-9.]+).*/\1/')
      ok=$(echo  "$line" | sed -E 's/.* ok=([0-9]+).*/\1/')
      RPS[$ep]=$r; P99[$ep]=$p99; P50[$ep]=$p50
      echo "METRIC h1_${ep}_p99_us=$p99"
      echo "METRIC h1_${ep}_p50_us=$p50"
      echo "METRIC h1_${ep}_rps=$r"
      [ "$ok" = "1" ] || ALL_OK=0
      ;;
  esac
done <<<"$(echo "$OUT" | grep -E '^RESULT')"

echo "METRIC h1_peak_rss_kb=$RSS_KB"

# Geomeans: p99 (primary, lower better), p50, rps (throughput guard).
python3 - "$ALL_OK" \
  "${P99[root]:-0}" "${P99[user_id]:-0}" "${P99[static_1k]:-0}" "${P99[echo_1k]:-0}" \
  "${P50[root]:-0}" "${P50[user_id]:-0}" "${P50[static_1k]:-0}" "${P50[echo_1k]:-0}" \
  "${RPS[root]:-0}" "${RPS[user_id]:-0}" "${RPS[static_1k]:-0}" "${RPS[echo_1k]:-0}" <<'PY'
import sys, math
ok = sys.argv[1]
p99 = [float(x) for x in sys.argv[2:6]]
p50 = [float(x) for x in sys.argv[6:10]]
rps = [float(x) for x in sys.argv[10:14]]
def gm(vals): return math.exp(sum(math.log(v) for v in vals) / len(vals))
if ok != "1" or any(v <= 0 for v in p99 + p50 + rps):
    print("METRIC h1_p99_us_geomean=0")
    print("METRIC h1_p50_us_geomean=0")
    print("METRIC h1_rps_geomean=0")
    print("METRIC success=0")
else:
    print(f"METRIC h1_p99_us_geomean={gm(p99):.2f}")
    print(f"METRIC h1_p50_us_geomean={gm(p50):.2f}")
    print(f"METRIC h1_rps_geomean={gm(rps):.0f}")
    print("METRIC success=1")
PY
