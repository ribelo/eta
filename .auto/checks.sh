#!/usr/bin/env bash
set -euo pipefail

nix develop -c dune build @signal-gates >/dev/null
nix develop -c dune runtest test/signal test/stream --force >/dev/null
