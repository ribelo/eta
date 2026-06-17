#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

bash -n .hill-climbing/h1-plain-echo-1k-throughput-20260615/measure.sh
bash -n .hill-climbing/h1-plain-echo-1k-throughput-20260615/trace_h1_echo_phase.sh

command -v oha >/dev/null
command -v go >/dev/null
command -v curl >/dev/null

nix develop -c dune build http-testsuite/test/server_load/h1_probe.exe
nix develop -c dune runtest --profile release test/http_eio test/http_common
