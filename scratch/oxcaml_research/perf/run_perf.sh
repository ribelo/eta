#!/usr/bin/env bash
# Runs the OCaml runtime bench exes once per toolchain, dumps each
# benchmark's raw output (one JSON object per benchmark) plus a
# minimal manifest.  Skips the TS and compile probes so the apples-to-apples
# OCaml vs OxCaml comparison is direct.
set -euo pipefail

cd "$(dirname "$0")/../../.."

label="${1:?label required: mainline | oxcaml}"
out="scratch/oxcaml_research/perf/${label}.json"
quick="${QUICK:-false}"

mkdir -p scratch/oxcaml_research/perf
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

dune build --profile=release \
  bench/runtime_core/runtime_core.exe \
  bench/runtime_concurrency/runtime_concurrency.exe \
  bench/runtime_observability/runtime_observability.exe \
  bench/runtime_overhead/runtime_overhead.exe \
  bench/runtime_real/runtime_real.exe \
  bench/runtime_stream/runtime_stream.exe \
  bench/runtime_schema/runtime_schema.exe

run_runtime() {
  local exe="$1"
  local args=()
  if [ "$quick" = "true" ]; then args+=("--quick"); fi
  "$exe" "${args[@]}" >> "$tmp"
}

start_ms="$(date +%s%3N)"
run_runtime _build/default/bench/runtime_core/runtime_core.exe
run_runtime _build/default/bench/runtime_concurrency/runtime_concurrency.exe
run_runtime _build/default/bench/runtime_observability/runtime_observability.exe
run_runtime _build/default/bench/runtime_overhead/runtime_overhead.exe
run_runtime _build/default/bench/runtime_real/runtime_real.exe
run_runtime _build/default/bench/runtime_stream/runtime_stream.exe
run_runtime _build/default/bench/runtime_schema/runtime_schema.exe
end_ms="$(date +%s%3N)"
duration_ms="$((end_ms - start_ms))"

ocaml_version="$(ocamlc -version 2>/dev/null || echo unknown)"
dune_version="$(dune --version 2>/dev/null || echo unknown)"
cpu_model="$(awk -F: '/model name/ {gsub(/^ /, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
[ -z "$cpu_model" ] && cpu_model="unknown"

{
  printf '{\n'
  printf '  "label": "%s",\n' "$label"
  printf '  "ocaml_version": "%s",\n' "$ocaml_version"
  printf '  "dune_version": "%s",\n' "$dune_version"
  printf '  "cpu_model": "%s",\n' "$cpu_model"
  printf '  "quick": %s,\n' "$quick"
  printf '  "duration_ms": %s,\n' "$duration_ms"
  printf '  "benchmarks": [\n'
  awk 'NF { if (seen) print ","; printf "    %s", $0; seen=1 } END { if (seen) print "" }' "$tmp"
  printf '  ]\n'
  printf '}\n'
} > "$out"

echo "$out"
