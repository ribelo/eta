#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../../.." && pwd)"
cd "$root"

for probe in \
  t1_inbox \
  t2_mid_work_cancel \
  t3_ordered_results \
  t4_supervisor_order \
  t5_cause_portable \
  t6_observability \
  t7_timeout_clock \
  t8_no_eio_leakage \
  t9_skew_bench
do
  echo "== $probe =="
  "scratch/oxcaml_research/concurrency_model/h3_hardening/$probe/run.sh"
done

