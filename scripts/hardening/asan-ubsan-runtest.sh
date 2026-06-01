#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  exec "$(dirname "$0")/asan-ubsan.sh"
else
  exec "$(dirname "$0")/asan-ubsan.sh" runtest --force "$@"
fi
