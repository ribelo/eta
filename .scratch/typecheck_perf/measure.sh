#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
out=scratch/typecheck_perf/results
mkdir -p "$out"
measure() {
  name="$1"; shift
  start=$(date +%s%3N)
  if [ -x /usr/bin/time ]; then
    /usr/bin/time -f 'max_rss_kb=%M' -o "$out/${name}.rss" "$@"
  else
    "$@"
    printf 'max_rss_kb=unavailable\n' > "$out/${name}.rss"
  fi
  end=$(date +%s%3N)
  printf 'elapsed_ms=%s\n' "$((end - start))" > "$out/${name}.time"
}
rm -rf _build/default/scratch/typecheck_perf
measure clean_build nix develop -c dune build scratch/typecheck_perf
measure noop_build nix develop -c dune build scratch/typecheck_perf
touch scratch/typecheck_perf/tp_m25.ml
measure touch_mid nix develop -c dune build scratch/typecheck_perf
nix develop -c dune exec scratch/typecheck_perf/runtime_smoke.exe > "$out/runtime_smoke.out"
EFFET_NA0_PROBE=missing_env nix develop -c dune build scratch/typecheck_perf/neg_missing_env.exe 2> "$out/neg_missing_env.err" || true
EFFET_NA0_PROBE=error_row nix develop -c dune build scratch/typecheck_perf/neg_error_row.exe 2> "$out/neg_error_row.err" || true
EFFET_NA0_PROBE=supervisor_escape nix develop -c dune build scratch/typecheck_perf/neg_supervisor_escape.exe 2> "$out/neg_supervisor_escape.err" || true
EFFET_NA0_PROBE=value_restriction nix develop -c dune build scratch/typecheck_perf/neg_value_restriction.exe 2> "$out/neg_value_restriction.err" || true
for f in "$out"/*.err; do printf '%s lines=%s bytes=%s\n' "$(basename "$f")" "$(wc -l < "$f")" "$(wc -c < "$f")"; done > "$out/error_sizes.txt"
