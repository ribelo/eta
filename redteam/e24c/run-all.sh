#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
"$here/run-old-style-negative.sh"
"$here/run-recipe.sh"
"$here/run-invariant-law.sh"
cat <<'OUT'
PASS: non-destructive E24c red-team checks
MANUAL: follow redteam/e24c/INVARIANT_BREAK.md for the throwaway corruption proof
OUT
