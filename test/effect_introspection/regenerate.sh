#!/usr/bin/env bash
set -euo pipefail

ROOT="${DUNE_SOURCEROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
dune exec ./test/effect_introspection/snapshot_effect_describe.exe \
  > test/effect_introspection/expected_descriptions.txt
