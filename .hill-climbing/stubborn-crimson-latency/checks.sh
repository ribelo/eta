#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

nix develop -c dune runtest --profile release test/http_eio test/http_common
