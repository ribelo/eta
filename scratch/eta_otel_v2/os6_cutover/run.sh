#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../.."

mkdir -p scratch/eta_otel_v2/os6_cutover/results

dune build --profile=release bench/runtime_observability/runtime_observability.exe

_build/default/bench/runtime_observability/runtime_observability.exe \
  --filter 'eta_otel.encoder' \
  --samples 5 \
  > scratch/eta_otel_v2/os6_cutover/results/encoder-current.jsonl

if rg -n 'effet-otel|Effet_otel|effet_otel|packages/effet-otel' \
  packages bench docs README.md dune-project *.opam \
  --glob '!bench/results/**' \
  > scratch/eta_otel_v2/os6_cutover/results/legacy-imports.txt
then
  cat scratch/eta_otel_v2/os6_cutover/results/legacy-imports.txt
  exit 1
fi

printf 'encoder_results=scratch/eta_otel_v2/os6_cutover/results/encoder-current.jsonl\n'
printf 'legacy_imports=none\n'
