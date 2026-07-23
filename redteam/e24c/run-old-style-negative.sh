#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"

# Negative source and verbatim compiler snapshots belong to the repository's
# existing type-error corpus; this red-team probe deliberately does not clone
# those fixtures.
test -f test/type_errors/cases/schedule_ternary_negative.ml
test -f test/type_errors/cases/schedule_tap_input_negative.ml
nix develop -c dune runtest test/type_errors --force

rg -q 'schedule_ternary_negative\.ml' test/type_errors/expected_compile.txt
rg -q 'schedule_tap_input_negative\.ml' test/type_errors/expected_compile.txt
rg -A12 'schedule_ternary_negative\.ml' test/type_errors/expected_compile.txt \
  | grep -Eq 'expects 2 argument|applied to 3 argument'
rg -A12 'schedule_tap_input_negative\.ml' test/type_errors/expected_compile.txt \
  | grep -Eq 'Unbound value .*Schedule\.tap_input'
printf '%s\n' 'PASS: canonical snapshots show ternary Schedule.t and tap_input fail loudly'
