#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../../../.."

RESULTS="scratch/eta_ai_v1/probes/live_reach/results"
LOG="$RESULTS/live_reach_latest.txt"
mkdir -p "$RESULTS"

dune exec ./scratch/eta_ai_v1/probes/live_reach/live_reach.exe -- "$@" \
  | tee "$LOG"
