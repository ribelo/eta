#!/usr/bin/env bash
set -u

cd "$(dirname "$0")"

dune build --root . ./fixtures/runtime_smoke.exe
_build/default/fixtures/runtime_smoke.exe

run_negative() {
  env_name="$1"
  target="$2"
  pattern="$3"
  log="_build/${env_name}.log"

  if HANDLED_EFFECT_NEG="$env_name" dune build --root . "./fixtures/${target}.exe" >"$log" 2>&1; then
    echo "${env_name}: expected compile failure, but build succeeded" >&2
    exit 1
  fi

  if ! grep -Eq "$pattern" "$log"; then
    echo "${env_name}: compile failure did not match expected pattern" >&2
    cat "$log" >&2
    exit 1
  fi

  echo "${env_name} PASS"
}

run_negative zero_arg_auto_di neg_zero_arg_auto_di "Log_eff\\.t|expected of type"
run_negative escape_handler neg_escape_handler "local.*parent|expected to be \"global\""
run_negative continue_missing_forward_handler neg_continue_missing_forward_handler "Log_eff\\.t \\* unit|not compatible with type \"unit\""
run_negative eio_fiber_capture neg_eio_fiber_capture "db_h.*local|expected to be \"global\""

echo "handled_effect R-channel evidence passed"
