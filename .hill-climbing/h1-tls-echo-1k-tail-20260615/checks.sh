#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="/tmp/eta-h1-tls-echo-check.out"

cd "$ROOT"

bash -n .hill-climbing/h1-tls-echo-1k-tail-20260615/measure.sh
bash -n .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_echo_custom_client.sh
bash -n .hill-climbing/h1-tls-echo-1k-tail-20260615/trace_h1_oha_phases.sh
python -m py_compile .hill-climbing/h1-tls-echo-1k-tail-20260615/h1_gap_client.py

nix develop -c dune build \
  http-testsuite/test/server_load/h1_probe.exe \
  http-testsuite/test/server_load/h1_tls_probe.exe

ETA_H1_TLS_ECHO_REQUESTS=128 \
ETA_H1_TLS_ECHO_REPEATS=1 \
  bash .hill-climbing/h1-tls-echo-1k-tail-20260615/measure.sh >"$OUT"

grep -q '^METRIC h1_echo_1k_success=1.000000$' "$OUT"
grep -q '^METRIC h1_tls_echo_1k_p99_us=' "$OUT"
grep -q '^METRIC h1_plain_echo_1k_p99_us=' "$OUT"
grep -q '^METRIC h1_tls_static_1k_p99_us=' "$OUT"
grep -q '^METRIC h1_tls_root_p99_us=' "$OUT"
grep -q '^METRIC h1_tls_post_user_p99_us=' "$OUT"
grep -q '^METRIC h1_tls_user_id_p99_us=' "$OUT"
grep -q '^METRIC h1_tls_rps_geomean=' "$OUT"

nix develop -c dune runtest --profile release test/http_eio test/http_common
