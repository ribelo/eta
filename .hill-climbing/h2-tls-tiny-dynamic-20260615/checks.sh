#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cd "$ROOT"

nix develop -c dune build \
  http-testsuite/test/server_load/h2_tls_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

ETA_H2_TLS_TINY_REQUESTS=64 ETA_H2_TLS_TINY_REPEATS=1 \
  bash .hill-climbing/h2-tls-tiny-dynamic-20260615/measure.sh \
  >/tmp/eta-h2-tls-tiny-check.out

grep -q '^METRIC h2_tls_success=1.000000$' \
  /tmp/eta-h2-tls-tiny-check.out
grep -q '^METRIC h2_tls_root_p99_us=' \
  /tmp/eta-h2-tls-tiny-check.out
grep -q '^METRIC h2_tls_static_1k_p99_us=' \
  /tmp/eta-h2-tls-tiny-check.out
grep -q '^METRIC h2_tls_echo_1k_p99_us=' \
  /tmp/eta-h2-tls-tiny-check.out

PORT="${ETA_H2_TLS_TINY_CHECK_PORT:-$((22000 + RANDOM % 20000))}"
SERVER_TMP="$TMP_DIR/server"
SERVER_LOG="$TMP_DIR/server.log"
SERVER_H2_TRACE="$TMP_DIR/server-h2.log"
SERVER_TLS_TRACE="$TMP_DIR/server-tls.log"
CLIENT_TLS_TRACE="$TMP_DIR/client-tls.log"
CLIENT_TSV="$TMP_DIR/client.tsv"
mkdir -p "$SERVER_TMP"

ETA_H2_ECHO_TRACE_PATH="$SERVER_H2_TRACE" \
ETA_TLS_IO_TRACE_PATH="$SERVER_TLS_TRACE" \
  _build/default/http-testsuite/test/server_load/h2_tls_probe.exe \
  "$PORT" "$SERVER_TMP" >"$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

ready=0
for _ in $(seq 1 200); do
  if grep -q "READY $PORT" "$SERVER_LOG"; then
    ready=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  sleep 0.05
done

if [[ "$ready" -ne 1 ]]; then
  cat "$SERVER_LOG" >&2
  exit 1
fi

ETA_H2_GAP_TLS_CA_FILE="$SERVER_TMP/certs/ca.pem" \
ETA_H2_GAP_METHOD=GET \
ETA_H2_GAP_BODY_BYTES=0 \
ETA_H2_GAP_TIMEOUT=10 \
ETA_TLS_IO_TRACE_PATH="$CLIENT_TLS_TRACE" \
  _build/default/http-testsuite/test/server_load/h2_gap_client.exe \
  127.0.0.1 "$PORT" 64 16 1 "$CLIENT_TSV" /

awk -F '\t' '
  NR > 1 {
    n++
    if ($5 < 0 || $6 < 0 || $7 < 0 || $8 != 200 || $9 != 0 || $10 != "") bad++
    if (!($4 <= $5 && $5 <= $6 && $6 <= $7)) bad++
    if ($11 < 0 || $12 < 0) bad++
    if ($13 < 0 || !($4 <= $13 && $13 <= $5)) bad++
    if ($14 < 0 || $15 < 0 || !($11 <= $14 && $14 <= $15)) bad++
  }
  END {
    if (n != 64 || bad > 0) {
      printf("bad TLS checkpoint smoke output: n=%d bad=%d\n", n, bad) > "/dev/stderr"
      exit 1
    }
  }
' "$CLIENT_TSV"

grep -q 'h2_ingress_plain_read' "$SERVER_H2_TRACE"
grep -q 'h2_request_accepted' "$SERVER_H2_TRACE"
grep -q 'h2_write_flow_complete' "$SERVER_H2_TRACE"
grep -q 'tls_raw_read' "$SERVER_TLS_TRACE"
grep -q 'tls_raw_write' "$SERVER_TLS_TRACE"
grep -q 'tls_raw_read' "$CLIENT_TLS_TRACE"
grep -q 'tls_raw_write' "$CLIENT_TLS_TRACE"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

nix develop -c dune runtest --profile release test/http_eio test/http_common
