#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
"$here/signature-census.sh"
"$here/run-policy-sequence.sh"
"$here/run-no-hook.sh"
"$here/run-c-seam.sh"
"$here/run-d-deletion.sh"
