#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export EIO_BACKEND="${EIO_BACKEND:-posix}"

log=$(mktemp)
trap 'rm -f "$log"' EXIT

if ! nix develop -c dune build @signal-gates @install >"$log" 2>&1; then
  tail -80 "$log"
  exit 1
fi
