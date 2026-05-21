#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

quick=false
filter=""
out=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quick) quick=true; shift ;;
    --filter) filter="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

mkdir -p bench/results
start_ms="$(date +%s%3N)"

commit="$(git rev-parse HEAD)"
commit_time="$(git show -s --format=%cI HEAD)"
run_time="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
short="$(git rev-parse --short HEAD)"
dirty="false"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  dirty="true"
fi

if [ -z "$out" ]; then
  out="bench/results/${stamp}-${short}.json"
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

run_runtime() {
  exe="$1"
  args=()
  if [ "$quick" = true ]; then args+=("--quick"); fi
  if [ -n "$filter" ]; then args+=("--filter" "$filter"); fi
  "$exe" "${args[@]}" >> "$tmp"
}

dune build --profile=release \
  bench/runtime_core/runtime_core.exe \
  bench/runtime_concurrency/runtime_concurrency.exe \
  bench/runtime_observability/runtime_observability.exe \
  bench/runtime_overhead/runtime_overhead.exe \
  bench/runtime_real/runtime_real.exe \
  bench/runtime_stream/runtime_stream.exe \
  bench/runtime_schema/runtime_schema.exe \
  bench/compare.exe \
  bench/overhead.exe

run_runtime _build/default/bench/runtime_core/runtime_core.exe
run_runtime _build/default/bench/runtime_concurrency/runtime_concurrency.exe
run_runtime _build/default/bench/runtime_observability/runtime_observability.exe
run_runtime _build/default/bench/runtime_overhead/runtime_overhead.exe
run_runtime _build/default/bench/runtime_real/runtime_real.exe
run_runtime _build/default/bench/runtime_stream/runtime_stream.exe
run_runtime _build/default/bench/runtime_schema/runtime_schema.exe

ts_args=()
if [ "$quick" = true ]; then ts_args+=("--quick"); fi
if [ -n "$filter" ]; then ts_args+=("--filter" "$filter"); fi
bench/runtime_overhead_ts/run.sh "${ts_args[@]}" >> "$tmp"

compile_args=()
if [ "$quick" = true ]; then compile_args+=("--quick"); fi
if [ -n "$filter" ]; then compile_args+=("--filter" "$filter"); fi
bench/compile/run_compile.sh "${compile_args[@]}" >> "$tmp"

end_ms="$(date +%s%3N)"
duration_ms="$((end_ms - start_ms))"
cpu_model="$(awk -F: '/model name/ {gsub(/^ /, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
if [ -z "$cpu_model" ]; then cpu_model="unknown"; fi
cpu_count="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unknown)"
ocaml_version="$(ocamlc -version 2>/dev/null || echo unknown)"
dune_version="$(dune --version 2>/dev/null || echo unknown)"

{
  printf '{\n'
  printf '  "schema_version": 1,\n'
  printf '  "commit": "%s",\n' "$commit"
  printf '  "commit_time": "%s",\n' "$commit_time"
  printf '  "run_time": "%s",\n' "$run_time"
  printf '  "dirty": %s,\n' "$dirty"
  printf '  "machine": {\n'
  printf '    "os": "%s",\n' "$(uname -s)"
  printf '    "kernel": "%s",\n' "$(uname -r)"
  printf '    "cpu_model": "%s",\n' "$cpu_model"
  printf '    "cpu_count": "%s",\n' "$cpu_count"
  printf '    "ocaml_version": "%s",\n' "$ocaml_version"
  printf '    "dune_version": "%s"\n' "$dune_version"
  printf '  },\n'
  printf '  "duration_ms": %s,\n' "$duration_ms"
  printf '  "benchmarks": [\n'
  awk 'NF { if (seen) print ","; printf "    %s", $0; seen=1 } END { if (seen) print "" }' "$tmp"
  printf '  ]\n'
  printf '}\n'
} > "$out"

echo "$out"
