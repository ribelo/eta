#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"

bash scratch/oxcaml_research/concurrency_model/h3_caveats/c1_random/run.sh
bash scratch/oxcaml_research/concurrency_model/h3_caveats/c3_supervisor_order/run.sh
