#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

bash -n .hill-climbing/h2-plain-post-user-4x4-p99-20260615/measure.sh
bash -n .hill-climbing/h2-plain-post-user-4x4-p99-20260615/trace_h2_4x4_phase.sh

command -v oha >/dev/null
command -v node >/dev/null

nix develop -c dune build http-testsuite/test/server_load/h2_probe.exe
nix develop -c dune runtest --profile release test/http_eio test/http_common
