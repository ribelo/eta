#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
cd "$root"
name='Schedule.and_then tags every first phase output before every second phase output'
rg -Fq "$name" test/laws/law_properties.ml

set +e
output=$(nix develop -c dune runtest test/laws --force 2>&1)
status=$?
set -e
printf '%s\n' "$output"

if [[ ${EXPECT_FAILURE:-0} == 1 ]]; then
  test "$status" -ne 0
  grep -Fq "$name" <<<"$output"
  printf '%s\n' 'PASS: named and_then law rejected the throwaway invariant break'
else
  test "$status" -eq 0
  printf '%s\n' 'PASS: schedule law baseline is green'
fi
