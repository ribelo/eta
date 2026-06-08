#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"

out="scratch/effet_research/blocking/run.out"
: > "$out"

run() {
  local exe="$1"
  echo "## $exe" | tee -a "$out"
  dune exec "$exe" | tee -a "$out"
}

run scratch/effet_research/blocking/baselines/direct_blocking_eio_freeze.exe
run scratch/effet_research/blocking/baselines/eio_run_in_systhread_smoke.exe
run scratch/effet_research/blocking/baselines/eio_run_in_systhread_stress.exe

run scratch/effet_research/blocking/c_stubs/release_lock_sleep.exe
run scratch/effet_research/blocking/c_stubs/hold_lock_sleep.exe
run scratch/effet_research/blocking/c_stubs/hold_lock_cpu.exe

run scratch/effet_research/blocking/bounded_pool/pool_smoke.exe
run scratch/effet_research/blocking/bounded_pool/pool_backpressure_wait.exe
run scratch/effet_research/blocking/bounded_pool/pool_backpressure_reject.exe
run scratch/effet_research/blocking/bounded_pool/pool_stress_thread_count.exe
run scratch/effet_research/blocking/bounded_pool/pool_shutdown_started_jobs.exe
run scratch/effet_research/blocking/bounded_pool/pool_shutdown_pending_jobs.exe
run scratch/effet_research/blocking/bounded_pool/pool_stress_matrix.exe

run scratch/effet_research/blocking/cancellation/cancel_pending_positive.exe
run scratch/effet_research/blocking/cancellation/cancel_started_documents_nonpreemptive.exe
run scratch/effet_research/blocking/cancellation/cancel_with_user_cancel_handle.exe
run scratch/effet_research/blocking/cancellation/detach_after_cancel.exe

run scratch/effet_research/blocking/resource_classes/shared_pool_starvation.exe
run scratch/effet_research/blocking/resource_classes/db_fs_separate_pools.exe
run scratch/effet_research/blocking/resource_classes/per_pool_limits.exe

run scratch/effet_research/blocking/domain_isolated_optional/domain_pool_hold_lock_positive.exe

run scratch/effet_research/blocking/api_ergonomics/cpu_vs_island/same_domain_thunk.exe
run scratch/effet_research/blocking/api_ergonomics/cpu_vs_island/blocking_pool.exe
run scratch/effet_research/blocking/api_ergonomics/cpu_vs_island/island_pool.exe

run scratch/effet_research/blocking/api_ergonomics/error_model/blocking_returns_value.exe
run scratch/effet_research/blocking/api_ergonomics/error_model/blocking_raises_exn.exe
run scratch/effet_research/blocking/api_ergonomics/error_model/blocking_raises_after_cancel.exe
run scratch/effet_research/blocking/api_ergonomics/error_model/blocking_raises_after_detach.exe
run scratch/effet_research/blocking/api_ergonomics/error_model/typed_errors_via_result.exe

run scratch/effet_research/blocking/api_ergonomics/worker_restrictions/worker_calls_eio_stream_add.exe
run scratch/effet_research/blocking/api_ergonomics/worker_restrictions/worker_calls_runtime_run.exe
run scratch/effet_research/blocking/api_ergonomics/worker_restrictions/worker_calls_nested_blocking.exe
run scratch/effet_research/blocking/api_ergonomics/worker_restrictions/worker_resolves_parent_promise.exe

run scratch/effet_research/blocking/api_ergonomics/observability/pool_stats.exe
run scratch/effet_research/blocking/api_ergonomics/observability/job_timings.exe
run scratch/effet_research/blocking/api_ergonomics/observability/trace_labels.exe
