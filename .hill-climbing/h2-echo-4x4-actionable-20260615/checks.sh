#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="/tmp/eta-h2-echo-4x4-check.out"

cd "$ROOT"

bash -n .hill-climbing/h2-echo-4x4-actionable-20260615/measure.sh
bash -n .hill-climbing/h2-echo-4x4-actionable-20260615/trace_echo_4x4_custom_client.sh
bash -n .hill-climbing/h2-echo-4x4-actionable-20260615/trace_echo_4x4_syscalls.sh

nix develop -c dune build \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_tls_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

ETA_H2_ECHO_4X4_REQUESTS=128 \
ETA_H2_ECHO_4X4_REPEATS=1 \
  bash .hill-climbing/h2-echo-4x4-actionable-20260615/measure.sh >"$OUT"

grep -q '^METRIC h2_echo_4x4_success=1.000000$' "$OUT"
grep -q '^METRIC h2_plain_echo_4x4_p99_us=' "$OUT"
grep -q '^METRIC h2_tls_echo_4x4_p99_us=' "$OUT"
grep -q '^METRIC h2_plain_echo_1x16_p99_us=' "$OUT"
grep -q '^METRIC h2_plain_static_4x4_p99_us=' "$OUT"
grep -q '^METRIC h2_plain_post_4x4_p99_us=' "$OUT"
grep -q '^METRIC h2_plain_root_4x4_p99_us=' "$OUT"
grep -q '^METRIC h2_echo_4x4_rps_geomean=' "$OUT"

nix develop -c dune runtest --profile release test/http_eio test/http_common
