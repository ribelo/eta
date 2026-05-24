#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../../.."

RESULTS="scratch/eta_ai_v1/probes/streaming_sse/results"
mkdir -p "$RESULTS"

dune exec scratch/eta_ai_v1/probes/streaming_sse/sse_probe.exe \
  | tee "$RESULTS/sse_probe.txt"
