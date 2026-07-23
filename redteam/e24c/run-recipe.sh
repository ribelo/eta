#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"

test "$(rg -l 'retry attempts can be observed without schedule taps' \
  test/core_common/effect_retry_repeat_common_suites.ml | wc -l)" -eq 1
# The recipe is shared by both native backends; core_eio is the focused native
# integration target available in the OxCaml shell.
nix develop -c dune runtest test/core_eio --force
printf '%s\n' 'PASS: named retry-attempt observation recipe passed in core_eio'
