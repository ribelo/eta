#!/usr/bin/env bash
set -euo pipefail

SESSION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SESSION_DIR/../.." && pwd)"

cd "$ROOT"

bash -n "$SESSION_DIR/measure.sh"
command -v oha >/dev/null
nix develop -c dune build http-testsuite/test/server_load/run.exe
nix develop -c dune runtest --profile release test/http_eio test/http_common
