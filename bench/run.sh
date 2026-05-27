#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Default to the posix Eio backend for harness stability. The io_uring backend
# locks pages per-ring; repeated [Eio_main.run] cycles in benches like
# runtime_real (n=20 samples * 8 rows) accumulate memlocked pages faster than
# the kernel releases them, hitting ENOMEM on hosts with default
# `ulimit -l` (8 MB on most distros). Both v1 and v2 are measured under the
# same backend, so this does not bias A/B comparisons. Override by exporting
# EIO_BACKEND before invoking this script.
export EIO_BACKEND="${EIO_BACKEND:-posix}"

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

build_targets=(
  lib/eta/bench/bench_eta.exe
  lib/stream/bench/bench_stream.exe
  lib/schema/bench/bench_schema.exe
  lib/otel/bench/bench_otel.exe
  lib/par/bench/bench_par.exe
  lib/http_bench/bench_http.exe
  lib/sql/bench/bench_sql.exe
  lib/ai/bench/bench_ai.exe
  lib/ai/openai_codec/bench/bench_ai_openai_codec.exe
  lib/ai/openai/bench/bench_ai_openai.exe
  lib/ai/anthropic/bench/bench_ai_anthropic.exe
  lib/ai/openai_compat/bench/bench_ai_openai_compat.exe
  lib/ai/openrouter/bench/bench_ai_openrouter.exe
  lib/redacted/bench/bench_redacted.exe
  lib/test/bench/bench_test.exe
  lib/schema_test/bench/bench_schema_test.exe
  lib/ppx/bench/bench_ppx.exe
  bench/compare.exe
  bench/overhead.exe
)

for target in "${build_targets[@]}"; do
  dune build -j 1 "$target"
done

run_runtime _build/default/lib/eta/bench/bench_eta.exe
run_runtime _build/default/lib/stream/bench/bench_stream.exe
run_runtime _build/default/lib/schema/bench/bench_schema.exe
run_runtime _build/default/lib/otel/bench/bench_otel.exe
run_runtime _build/default/lib/par/bench/bench_par.exe
run_runtime _build/default/lib/http_bench/bench_http.exe
run_runtime _build/default/lib/sql/bench/bench_sql.exe
run_runtime _build/default/lib/ai/bench/bench_ai.exe
run_runtime _build/default/lib/ai/openai_codec/bench/bench_ai_openai_codec.exe
run_runtime _build/default/lib/ai/openai/bench/bench_ai_openai.exe
run_runtime _build/default/lib/ai/anthropic/bench/bench_ai_anthropic.exe
run_runtime _build/default/lib/ai/openai_compat/bench/bench_ai_openai_compat.exe
run_runtime _build/default/lib/ai/openrouter/bench/bench_ai_openrouter.exe
run_runtime _build/default/lib/redacted/bench/bench_redacted.exe
run_runtime _build/default/lib/test/bench/bench_test.exe
run_runtime _build/default/lib/schema_test/bench/bench_schema_test.exe
run_runtime _build/default/lib/ppx/bench/bench_ppx.exe

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
