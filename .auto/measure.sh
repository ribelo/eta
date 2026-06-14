#!/usr/bin/env bash
# Autoresearch benchmark: Eta HTTPS (HTTP/1.1 over TLS) HANDSHAKE latency.
#
# Context: in the broad server-load suite, Eta H1 TLS shows a stable ~15-16ms
# p99 - the biggest outlier by far. Diagnosis (isolated, core-pinned):
#   * steady-state H1 TLS request latency is fine (~0.2ms p50, ~0.4ms p99);
#   * the p99 is ENTIRELY TLS HANDSHAKE cost. A single full handshake is
#     ECDHE-RSA with an RSA-2048 server signature (~1.4ms CPU). Under c=16 the
#     handshakes serialize on the single-core Eio server (p50 ~2.66ms), and at
#     the broad suite's n=1000 the 16 handshakes (1.6% of requests) land right
#     at p99 -> the reported ~15-16ms.
# The same Tls_eio path serves H2 TLS, so a faster handshake should help both.
#
# Hill: reduce per-handshake cost under concurrent load. We drive a standalone
# Eta HTTPS H1 server (h1_tls_probe.exe) with oha --disable-keepalive so EVERY
# request performs a fresh TLS handshake -> p50 is a clean, low-noise measure of
# handshake-under-load latency (can't be gamed by request-count ratios).
#
# Emits `METRIC name=value` lines on stdout.
#
# Primary metric: h1_tls_hs_p50_us (microseconds, LOWER is better) - median
# per-request latency when every request does a fresh handshake, c=16.
# Secondary monitors:
#   h1_tls_hs_p99_us  - handshake tail latency.
#   h1_tls_hs_rps     - handshake throughput (must NOT regress).
#   h1_tls_ka_p99_us  - keep-alive p99 at c=16 n=1000 (the broad-run symptom;
#                       confirms the win maps to the reported ~15-16ms number).
#   h1_tls_peak_rss_kb- server peak RSS.
#   success           - 1 only if every oha run kept successRate >= 0.999.
set -euo pipefail

cd "$(dirname "$0")/.."
export EIO_BACKEND="${EIO_BACKEND:-posix}"

EXE=_build/default/http-testsuite/test/server_load/h1_tls_probe.exe

# Release build: we optimize the shipping artifact.
nix develop -c dune build --profile release \
  http-testsuite/test/server_load/h1_tls_probe.exe 2>&1 | tail -20

# CPU pinning to cut scheduler/migration noise: server on core 2, load gen core 3.
SRV_PIN=""
OHA_PIN=""
if command -v taskset >/dev/null 2>&1; then
  SRV_PIN="taskset -c 2"
  OHA_PIN="taskset -c 3"
fi

C=16
HS_N="${ETA_TLS_HS_REQUESTS:-3000}"   # handshake run: fresh handshake per request
KA_N="${ETA_TLS_KA_REQUESTS:-1000}"   # keep-alive run: matches broad-suite Quick
REPS="${ETA_TLS_REPS:-3}"

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
    for _ in $(seq 1 200); do
      grep -q READY "$LOG" && break
      sleep 0.05
    done
    grep -q READY "$LOG" || { echo "PROBE_FAILED"; cat "$LOG"; exit 1; }

    URL="https://127.0.0.1:$PORT/"

    # sample <extra-oha-flags...> : emit "rps p99_us p50_us successRate"
    sample() {
      '"$OHA_PIN"' oha --no-tui --output-format json --http-version 1.1 \
        --insecure --redirect 0 --disable-compression "$@" "$URL" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); s=d[\"summary\"]; lp=d[\"latencyPercentiles\"]; print(\"%.0f %.2f %.2f %.4f\" % (s[\"requestsPerSec\"], lp[\"p99\"]*1e6, lp[\"p50\"]*1e6, s[\"successRate\"]))"
    }

    median() { printf "%s\n" "$@" | sort -n | awk "{a[NR]=\$1} END{print a[int((NR+1)/2)]}"; }

    note_rss() {
      if [ -r "/proc/$PID/status" ]; then
        hwm=$(awk "/VmHWM/{print \$2}" "/proc/$PID/status")
        [ -n "$hwm" ] && [ "$hwm" -gt "$PEAK_RSS" ] && PEAK_RSS=$hwm
      fi
    }

    # Warmup (prime server + RSA path + oha).
    sample --disable-keepalive -c '"$C"' -n 500 >/dev/null

    # --- Primary: fresh handshake per request (--disable-keepalive) ---
    hs_rps=(); hs_p99=(); hs_p50=(); ok=1
    for _ in $(seq 1 '"$REPS"'); do
      read -r r p99 p50 sr <<<"$(sample --disable-keepalive -c '"$C"' -n '"$HS_N"')"
      hs_rps+=("$r"); hs_p99+=("$p99"); hs_p50+=("$p50")
      awk "BEGIN{exit !($sr < 0.999)}" && ok=0
      note_rss
    done
    echo "RESULT_HS rps=$(median "${hs_rps[@]}") p99=$(median "${hs_p99[@]}") p50=$(median "${hs_p50[@]}") ok=$ok"

    # --- Secondary symptom: keep-alive p99 at broad-suite Quick shape ---
    ka_p99=(); ok2=1
    for _ in $(seq 1 '"$REPS"'); do
      read -r r p99 p50 sr <<<"$(sample -c '"$C"' -n '"$KA_N"')"
      ka_p99+=("$p99")
      awk "BEGIN{exit !($sr < 0.999)}" && ok2=0
      note_rss
    done
    echo "RESULT_KA p99=$(median "${ka_p99[@]}") ok=$ok2"
    echo "RESULT_MEM rss_kb=$PEAK_RSS"
  '
}

OUT=$(run_bench)
echo "$OUT" | grep -vE "^RESULT" || true

HS_RPS=0; HS_P99=0; HS_P50=0; KA_P99=0; RSS_KB=0; ALL_OK=1
while read -r line; do
  case "$line" in
    "RESULT_HS "*)
      HS_RPS=$(echo "$line" | sed -E 's/.* rps=([0-9.]+).*/\1/')
      HS_P99=$(echo "$line" | sed -E 's/.* p99=([0-9.]+).*/\1/')
      HS_P50=$(echo "$line" | sed -E 's/.* p50=([0-9.]+).*/\1/')
      ok=$(echo "$line" | sed -E 's/.* ok=([0-9]+).*/\1/'); [ "$ok" = "1" ] || ALL_OK=0
      ;;
    "RESULT_KA "*)
      KA_P99=$(echo "$line" | sed -E 's/.* p99=([0-9.]+).*/\1/')
      ok=$(echo "$line" | sed -E 's/.* ok=([0-9]+).*/\1/'); [ "$ok" = "1" ] || ALL_OK=0
      ;;
    "RESULT_MEM "*)
      RSS_KB=$(echo "$line" | sed -E 's/.*rss_kb=([0-9]+).*/\1/')
      ;;
  esac
done <<<"$(echo "$OUT" | grep -E '^RESULT')"

# Guard against a failed/empty run producing a fake "improvement".
if [ "$ALL_OK" != "1" ] || [ "$HS_P50" = "0" ] || [ "$HS_P99" = "0" ]; then
  echo "METRIC h1_tls_hs_p50_us=0"
  echo "METRIC h1_tls_hs_p99_us=0"
  echo "METRIC h1_tls_hs_rps=0"
  echo "METRIC h1_tls_ka_p99_us=0"
  echo "METRIC h1_tls_peak_rss_kb=$RSS_KB"
  echo "METRIC success=0"
else
  echo "METRIC h1_tls_hs_p50_us=$HS_P50"
  echo "METRIC h1_tls_hs_p99_us=$HS_P99"
  echo "METRIC h1_tls_hs_rps=$HS_RPS"
  echo "METRIC h1_tls_ka_p99_us=$KA_P99"
  echo "METRIC h1_tls_peak_rss_kb=$RSS_KB"
  echo "METRIC success=1"
fi
