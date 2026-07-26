#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 native|jsoo CASE DEPTH" >&2
  exit 64
fi

probe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
backend=$1
case_name=$2
depth=$3
timeout_seconds=${E35_TIMEOUT_SECONDS:-180}

case "$backend" in
  native)
    command=("$probe_dir/_build/default/probe_native.exe" "$case_name" "$depth")
    ;;
  jsoo)
    command=(node "$probe_dir/_build/default/probe_jsoo.bc.js" "$case_name" "$depth")
    ;;
  *)
    echo "unknown backend: $backend" >&2
    exit 64
    ;;
esac

set +e
output=$(timeout --signal=TERM --kill-after=5 "$timeout_seconds" "${command[@]}" 2>&1)
status=$?
set -e

if [[ $output == *"RESULT case="* ]]; then
  printf '%s\n' "$output" | grep 'RESULT case=' | tail -n 1
  if [[ $status -ne 0 ]]; then
    printf 'WRAPPER_NOTE case=%s depth=%s exit_after_result=%s\n' \
      "$case_name" "$depth" "$status"
  fi
elif [[ $status -eq 124 || $status -eq 137 || $status -eq 143 ]]; then
  printf 'RESULT case=%s depth=%s status=FAIL mode=hang detail=timeout_%ss\n' \
    "$case_name" "$depth" "$timeout_seconds"
elif [[ $status -ge 128 ]]; then
  printf 'RESULT case=%s depth=%s status=FAIL mode=signal detail=exit_%s\n' \
    "$case_name" "$depth" "$status"
else
  compact=$(printf '%s' "$output" | tr '\n\r\t' '   ')
  printf 'RESULT case=%s depth=%s status=FAIL mode=process_exit detail=exit_%s_%s\n' \
    "$case_name" "$depth" "$status" "$compact"
fi
