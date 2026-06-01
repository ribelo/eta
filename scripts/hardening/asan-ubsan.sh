#!/usr/bin/env bash
set -euo pipefail

export CC="${CC:-clang}"
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:abort_on_error=1:strict_string_checks=1}"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}"

if [ "$#" -eq 0 ]; then
  set -- runtest --force test/sql test/http
fi

command="$1"
shift

exec dune "$command" --profile asan "$@"
