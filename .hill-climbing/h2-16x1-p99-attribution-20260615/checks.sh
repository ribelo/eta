#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="/tmp/eta-h2-16x1-check.out"

cd "$ROOT"

nix develop -c dune build \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_tls_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

bash -n .hill-climbing/h2-16x1-p99-attribution-20260615/pinning_sensitivity.sh
bash -n .hill-climbing/h2-16x1-p99-attribution-20260615/trace_root_perf_sched.sh

ETA_H2_16X1_REQUESTS=128 \
ETA_H2_16X1_REPEATS=1 \
ETA_H2_16X1_BROAD_REQUESTS=128 \
ETA_H2_16X1_BROAD_REPEATS=1 \
  bash .hill-climbing/h2-16x1-p99-attribution-20260615/measure.sh >"$OUT"

grep -q '^METRIC h2_16x1_success=1.000000$' "$OUT"
grep -q '^METRIC h2_tls_16x1_root_p99_us=' "$OUT"
grep -q '^METRIC h2_tls_16x1_echo_1k_p99_us=' "$OUT"
grep -q '^METRIC h2_plain_16x1_root_p99_us=' "$OUT"
grep -q '^METRIC h2_tls_16x1_root_broad_p99_us=' "$OUT"

PINNING_OUT="/tmp/eta-h2-16x1-pinning-check.out"
ETA_H2_16X1_PINNING_REQUESTS=160 \
  bash .hill-climbing/h2-16x1-p99-attribution-20260615/pinning_sensitivity.sh \
  >"$PINNING_OUT"

grep -q '^METRIC h2_16x1_pinning_default_total_p99_us=' "$PINNING_OUT"
grep -q '^METRIC h2_16x1_pinning_best_total_p99_us=' "$PINNING_OUT"
grep -q '^METRIC h2_16x1_pinning_flow_rx_reduction_ratio=' "$PINNING_OUT"

nix develop -c dune runtest --profile release test/http_eio test/http_common
