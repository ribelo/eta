#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

bash -n .hill-climbing/h2-tls-spread-tiny-20260615/measure.sh
bash -n .hill-climbing/h2-tls-spread-tiny-20260615/trace_tiny_tls_write.sh
bash -n .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_custom_spread.sh
bash -n .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_runtime_probe.sh
bash -n .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_syscall_probe.sh
bash -n .hill-climbing/h2-tls-spread-tiny-20260615/trace_tls_aggregate_probe.sh
bash -n .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_custom_1x16_tls_root.sh
bash -n .hill-climbing/h2-tls-spread-tiny-20260615/trace_h2_custom_shape_matrix.sh

nix develop -c dune build \
  http-testsuite/test/server_load/run.exe \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_tls_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe \
  http-testsuite/test/server_load/tiny_tls_probe.exe

nix develop -c dune runtest --profile release test/http_eio test/http_common
