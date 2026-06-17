#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

if [ "${ETA_HILL_IN_NIX:-0}" != "1" ]; then
  export ETA_HILL_IN_NIX=1
  exec nix develop -c bash "$0"
fi

dune runtest --profile release test/http_eio test/http_common
