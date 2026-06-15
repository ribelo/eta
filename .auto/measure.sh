#!/usr/bin/env bash
# Autoresearch benchmark: Eta H2-over-TLS STEADY-STATE tail latency.
#
# Context: with H1 TLS handled (handshake serialization), the remaining weak
# spot is H2 TLS steady-state. Isolated measurement vs Go: Eta H2 TLS echo_1k
# p99 ~1.2-2.2ms vs Go ~0.74ms (1.6-3x). The gap is roughly uniform across
# non-file endpoints (root/user/echo all ~2ms p99 at c=16 p=16), so it is the
# shared H2+TLS request path, NOT a handshake artifact (keep-alive isolates
# steady state) and NOT the static_1k outlier (which is handler file-I/O).
#
# Hill: cut H2-over-TLS steady-state tail latency. echo_1k is the primary (full
# body read+write path, the user's cited gap); root/user/static are secondaries.
#
# Server: multi-domain (ETA_SERVER_DOMAINS) on isolated cores; oha on its own
# core set (NOT the bottleneck). Keep-alive, HTTP/2, c=16 p=16, n large, median
# of REPS -> low-noise steady-state p99.
#
# Emits `METRIC name=value` lines on stdout.
#
# Primary: h2_tls_echo_p99_us (LOWER is better).
# Secondary: per-endpoint p99/p50, rps_geomean (throughput guard), peak RSS,
#   success.
set -uo pipefail

cd "$(dirname "$0")/.."
export EIO_BACKEND="${EIO_BACKEND:-posix}"

EXE=_build/default/http-testsuite/test/server_load/h2_tls_probe.exe

# Release build: we optimize the shipping artifact.
nix develop -c dune build --profile release \
  http-testsuite/test/server_load/h2_tls_probe.exe 2>&1 | tail -20

# CPU pinning: server gets an isolated core set (multi-domain), oha its own.
SRV_PIN=""
OHA_PIN=""
if command -v taskset >/dev/null 2>&1; then
  SRV_PIN="taskset -c 4-19"
  OHA_PIN="taskset -c 20-27"
fi

DOMAINS="${ETA_TLS_DOMAINS:-8}"        # HTTPS accept/handshake domains
C="${ETA_H2TLS_C:-16}"                 # keep-alive connections
P="${ETA_H2TLS_P:-16}"                 # streams per connection
N="${ETA_H2TLS_REQUESTS:-20000}"       # requests per endpoint per rep
KA_N="${ETA_H2TLS_KA_N:-20000}"        # (same shape; keep-alive steady state)
REPS="${ETA_H2TLS_REPS:-3}"

run_bench() {
  nix develop -c bash -c '
    set -uo pipefail
    export EIO_BACKEND="'"$EIO_BACKEND"'"
    export ETA_SERVER_DOMAINS="'"$DOMAINS"'"
    PORT=$(shuf -i 20000-60000 -n1)
    TMP=$(mktemp -d)
    LOG=$(mktemp)
    '"$SRV_PIN"' '"$EXE"' "$PORT" "$TMP" >"$LOG" 2>&1 & PID=$!
    PEAK_RSS=0
    cleanup() { kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -rf "$TMP" "$LOG"; }
    trap cleanup EXIT
    for _ in $(seq 1 200); do
      grep -q READY "$LOG" && break
      sleep 0.05
    done
    grep -q READY "$LOG" || { echo "PROBE_FAILED"; cat "$LOG"; exit 1; }

    sample() {  # endpoint -> "rps p99_us p50_us successRate"
      '"$OHA_PIN"' oha --no-tui --output-format json --http-version 2 --insecure \
        --disable-compression -c '"$C"' -p '"$P"' -n '"$N"' \
        "https://127.0.0.1:$PORT$1" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); s=d[\"summary\"]; lp=d[\"latencyPercentiles\"]; print(\"%.0f %.2f %.2f %.4f\" % (s[\"requestsPerSec\"], lp[\"p99\"]*1e6, lp[\"p50\"]*1e6, s[\"successRate\"]))"
    }

    median() { printf "%s\n" "$@" | sort -n | awk "{a[NR]=\$1} END{print a[int((NR+1)/2)]}"; }
    note_rss() {
      if [ -r "/proc/$PID/status" ]; then
        hwm=$(awk "/VmHWM/{print \$2}" "/proc/$PID/status")
        [ -n "$hwm" ] && [ "$hwm" -gt "$PEAK_RSS" ] && PEAK_RSS=$hwm
      fi
      return 0
    }

    # Warmup.
    sample "/echo" >/dev/null

    declare -A EP=([root]="/" [user]="/user/123" [static_1k]="/static/1k.bin" [echo_1k]="/echo")
    for ep in echo_1k root user static_1k; do
      rps_v=(); p99_v=(); p50_v=(); ok=1
      for _ in $(seq 1 '"$REPS"'); do
        read -r r p99 p50 sr <<<"$(sample "${EP[$ep]}")"
        rps_v+=("${r:-0}"); p99_v+=("${p99:-0}"); p50_v+=("${p50:-0}")
        if [ -z "${sr:-}" ] || awk "BEGIN{exit !(${sr:-0} < 0.999)}"; then ok=0; fi
        note_rss
      done
      echo "RESULT $ep rps=$(median "${rps_v[@]}") p99=$(median "${p99_v[@]}") p50=$(median "${p50_v[@]}") ok=$ok"
    done
    echo "RESULT_MEM rss_kb=$PEAK_RSS"
  '
}

OUT=$(run_bench || true)
echo "$OUT" | grep -vE "^RESULT" || true

declare -A RPS P99 P50
ALL_OK=1; RSS_KB=0
while read -r line; do
  case "$line" in
    "RESULT_MEM "*)
      RSS_KB=$(echo "$line" | sed -E 's/.*rss_kb=([0-9]+).*/\1/') ;;
    "RESULT "*)
      ep=$(echo "$line" | awk '{print $2}')
      RPS[$ep]=$(echo "$line" | sed -E 's/.* rps=([0-9.]+).*/\1/')
      P99[$ep]=$(echo "$line" | sed -E 's/.* p99=([0-9.]+).*/\1/')
      P50[$ep]=$(echo "$line" | sed -E 's/.* p50=([0-9.]+).*/\1/')
      ok=$(echo "$line" | sed -E 's/.* ok=([0-9]+).*/\1/'); [ "$ok" = "1" ] || ALL_OK=0 ;;
  esac
done <<<"$(echo "$OUT" | grep -E '^RESULT')"

for ep in echo_1k root user static_1k; do
  echo "METRIC h2_tls_${ep}_p99_us=${P99[$ep]:-0}"
  echo "METRIC h2_tls_${ep}_p50_us=${P50[$ep]:-0}"
  echo "METRIC h2_tls_${ep}_rps=${RPS[$ep]:-0}"
done
echo "METRIC h2_tls_peak_rss_kb=$RSS_KB"

# Geomeans (rps, p50) + success. echo_1k p99 is reported separately as primary.
python3 - "$ALL_OK" \
  "${P50[echo_1k]:-0}" "${P50[root]:-0}" "${P50[user]:-0}" "${P50[static_1k]:-0}" \
  "${RPS[echo_1k]:-0}" "${RPS[root]:-0}" "${RPS[user]:-0}" "${RPS[static_1k]:-0}" <<'PY'
import sys, math
ok = sys.argv[1]
p50 = [float(x) for x in sys.argv[2:6]]
rps = [float(x) for x in sys.argv[6:10]]
def gm(vals): return math.exp(sum(math.log(v) for v in vals) / len(vals))
if ok != "1" or any(v <= 0 for v in p50 + rps):
    print("METRIC h2_tls_p50_us_geomean=0")
    print("METRIC h2_tls_rps_geomean=0")
    print("METRIC success=0")
else:
    print(f"METRIC h2_tls_p50_us_geomean={gm(p50):.2f}")
    print(f"METRIC h2_tls_rps_geomean={gm(rps):.0f}")
    print("METRIC success=1")
PY
