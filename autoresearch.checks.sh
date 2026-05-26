#!/usr/bin/env bash
# Fast correctness gate for Eta fanout autoresearch.

set -euo pipefail
cd "$(dirname "$0")"

nix develop -c dune build --profile=release packages/eta/eta.cmxa >/dev/null
nix develop -c dune runtest --force packages/eta/test >/dev/null
