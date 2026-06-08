#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../../.." && pwd)"
cd "$root"

out="scratch/effet_research/blocking/api_ergonomics/default_threads/results.out"
dune exec scratch/effet_research/blocking/api_ergonomics/default_threads/default_thread_probe.exe | tee "$out"
