#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"

bash scratch/oxcaml_research/recovery/r1_thunk_cancel/run.sh
bash scratch/oxcaml_research/recovery/r2_env_error/run.sh
bash scratch/oxcaml_research/recovery/r3_online_queue/run.sh
