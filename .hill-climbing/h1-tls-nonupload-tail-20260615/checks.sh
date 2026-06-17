#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="/tmp/eta-h1-tls-nonupload-check.out"

cd "$ROOT"

bash -n .hill-climbing/h1-tls-nonupload-tail-20260615/measure.sh

nix develop -c dune build \
  http-testsuite/test/server_load/h1_probe.exe \
  http-testsuite/test/server_load/h1_tls_probe.exe

ETA_H1_TLS_NONUPLOAD_REQUESTS=128 \
ETA_H1_TLS_NONUPLOAD_REPEATS=1 \
  bash .hill-climbing/h1-tls-nonupload-tail-20260615/measure.sh >"$OUT"

grep -q '^METRIC h1_tls_nonupload_success=1.000000$' "$OUT"
grep -q '^METRIC h1_tls_static_1k_p99_us=' "$OUT"
grep -q '^METRIC h1_tls_post_user_p99_us=' "$OUT"
grep -q '^METRIC h1_tls_user_id_p99_us=' "$OUT"
grep -q '^METRIC h1_tls_root_p99_us=' "$OUT"
grep -q '^METRIC h1_plain_static_1k_p99_us=' "$OUT"
grep -q '^METRIC h1_tls_nonupload_p99_geomean_us=' "$OUT"
grep -q '^METRIC h1_tls_rps_geomean=' "$OUT"

nix develop -c dune runtest --profile release test/http_eio test/http_common
