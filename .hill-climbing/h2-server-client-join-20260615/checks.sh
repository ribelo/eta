#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$ROOT"

nix develop -c dune build \
  http-testsuite/test/server_load/h2_probe.exe \
  http-testsuite/test/server_load/h2_gap_client.exe

ETA_H2_JOIN_REQUESTS=64 ETA_H2_JOIN_REPEATS=1 \
  bash .hill-climbing/h2-server-client-join-20260615/measure.sh >/tmp/eta-h2-join-check.out

grep -q '^METRIC h2c_join_success=1.000000$' /tmp/eta-h2-join-check.out

nix develop -c dune runtest --profile release test/http_eio test/http_common
