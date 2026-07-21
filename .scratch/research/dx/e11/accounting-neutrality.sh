#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$repo_root"

# Every legacy Eta_test `with_*` helper in this suite now uses the same decorated
# test-only contract, so this runs the existing helper regression suite under
# accounting. The `Run / fiber accounting preserves exit corpus` case also
# executes success, typed-failure, finalizer, structured-fiber, and race
# blueprints with `account_fibers=false` and `true` under otherwise identical
# Run construction and compares complete outcomes diagnostically.
nix develop -c dune runtest test/test --force
