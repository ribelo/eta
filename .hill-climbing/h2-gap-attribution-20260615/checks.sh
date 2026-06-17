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
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

PORT="${ETA_H2_GAP_CHECK_PORT:-$((22000 + RANDOM % 20000))}"
SERVER_TMP="$TMP_DIR/server"
SERVER_LOG="$TMP_DIR/server.log"
CLIENT_TSV="$TMP_DIR/client.tsv"
mkdir -p "$SERVER_TMP"

_build/default/http-testsuite/test/server_load/h2_probe.exe \
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

_build/default/http-testsuite/test/server_load/h2_gap_client.exe \
  127.0.0.1 "$PORT" 64 16 1 "$CLIENT_TSV"

awk -F '\t' '
  NR > 1 {
    n++
    if ($5 < 0 || $6 < 0 || $7 < 0 || $8 != 200 || $9 != 1024 || $10 != "") bad++
    if (!($4 <= $5 && $5 <= $6 && $6 <= $7)) bad++
  }
  END {
    if (n != 64 || bad > 0) {
      printf("bad smoke output: n=%d bad=%d\n", n, bad) > "/dev/stderr"
      exit 1
    }
  }
' "$CLIENT_TSV"

nix develop -c dune runtest --profile release test/http_eio test/http_common
