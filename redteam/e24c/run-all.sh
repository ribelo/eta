#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
"$here/run-old-style-negative.sh"
"$here/run-recipe.sh"
"$here/run-invariant-law.sh"
cat <<'OUT'
PASS: E24c red-team checks; committed invariant-break/revert evidence is recorded in INVARIANT_BREAK.md
OUT
