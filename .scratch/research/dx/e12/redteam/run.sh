#!/usr/bin/env bash
set -euo pipefail

ROOT="${DUNE_SOURCEROOT:-$(cd "$(dirname "$0")/../../../../.." && pwd)}"
cd "$ROOT"
dune exec ./test/effect_introspection/redteam_effect_audit.exe \
  > .scratch/research/dx/e12/redteam/output.txt
