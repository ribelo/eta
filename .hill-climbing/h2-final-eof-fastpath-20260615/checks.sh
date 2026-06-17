#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

nix develop -c dune build \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

ETA_H2_BODY_REQUESTS=64 ETA_H2_BODY_REPEATS=1 \
  bash .hill-climbing/h2-final-eof-fastpath-20260615/measure.sh \
  >/tmp/eta-h2-final-eof-fastpath-check.out

grep -q '^METRIC h2_body_success=1.000000$' \
  /tmp/eta-h2-final-eof-fastpath-check.out
grep -q '^METRIC h2_body_final_chunk_fraction=1.000000$' \
  /tmp/eta-h2-final-eof-fastpath-check.out
grep -q '^METRIC h2_body_owner_eof_read_fraction=0.000000$' \
  /tmp/eta-h2-final-eof-fastpath-check.out

nix develop -c dune runtest --profile release test/http_eio test/http_common
