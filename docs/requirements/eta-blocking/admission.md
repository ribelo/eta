---
kind: requirement
---
# Blocking-worker admission

## Intent

Let callers select waiting or fail-fast admission for a complete native
callback without duplicating Eta's worker-pool ownership. The blocking pool owns
admission from reservation through physical callback completion. The caller
owns domain failures and composes deadlines from ordinary Eta effects.

A worker claim occurs when a worker starts the callback wrapper. An admitted
queue entry has entered the configured bounded queue. An admission waiter is an
ordinary `run` caller that has not obtained a worker slot or queue entry.

## Requirements

- The `Eta_blocking` module shall expose `admission_failure` with the cases `Saturated` and `Shutting_down`. ^blockadm-8w9l
- The `Eta_blocking` module shall expose `'a try_run_outcome` with the cases `Completed of 'a` and `Not_run of admission_failure`. ^blockadm-dc1z
- The `Eta_blocking` module shall expose `try_run` with the same pool, name, and cancellation-hook inputs as `run`. ^blockadm-jazl
- The `Eta_blocking` module shall expose `try_run_result` with the same pool, name, and cancellation-hook inputs as `run_result`. ^blockadm-3vwr
- `Eta_blocking.Pool.config` shall consist of `max_threads`, `max_queued`, and `shutdown_policy`. ^blockadm-5bnu
- Each `Eta_blocking.Pool.t` value shall own its worker slots, bounded queue, admission waiters, and shutdown state. ^blockadm-tjyz
- When `run` finds an open pool with an available worker slot, the blocking pool shall admit the callback to that worker slot. ^blockadm-uazq
- When `run` finds all worker slots occupied and the bounded queue has capacity, the blocking pool shall admit the callback to the bounded queue. ^blockadm-2q6m
- When `run` finds all worker slots occupied and the bounded queue full, the blocking pool shall wait for admission until capacity becomes available, the caller is interrupted, or pool shutdown begins. ^blockadm-jqh0
- When `try_run` or `try_run_result` finds an open pool with an available worker slot, the blocking pool shall reserve one worker slot atomically before the callback starts. ^blockadm-43yc
- If `try_run` or `try_run_result` finds all worker slots occupied, then the operation shall return `Not_run Saturated`. ^blockadm-2r7p
- If `try_run` or `try_run_result` finds all worker slots occupied, then the blocking pool shall not enter the callback in the bounded queue. ^blockadm-ycfp
- If `try_run` or `try_run_result` finds all worker slots occupied, then the blocking pool shall not run the callback. ^blockadm-taew
- If `try_run` or `try_run_result` observes that pool shutdown prevents admission, then the operation shall return `Not_run Shutting_down`. ^blockadm-2qg5
- If `try_run` or `try_run_result` observes that pool shutdown prevents admission, then the blocking pool shall not run the callback. ^blockadm-6nox
- When a callback supplied to `try_run` returns normally, `try_run` shall return `Completed` with the callback value. ^blockadm-69e5
- When a callback supplied to `try_run_result` returns `Ok value`, `try_run_result` shall return `Completed value`. ^blockadm-0cun
- When a callback supplied to `try_run_result` returns `Error error`, `try_run_result` shall preserve `error` in the Eta typed-error channel. ^blockadm-ztyh
- If a callback supplied to `try_run` or `try_run_result` raises an ordinary OCaml exception, then the operation shall preserve the exception as an unchecked defect. ^blockadm-mz5m
- When caller interruption wins before the worker claim, the operation shall return interruption. ^blockadm-vpz2
- When caller interruption wins before the worker claim, the blocking pool shall prevent the callback from starting. ^blockadm-ov29
- When caller interruption wins before the worker claim, the blocking pool shall release all reserved admission state exactly once. ^blockadm-02pb
- When caller interruption wins before the worker claim, the blocking pool shall increment `cancelled_before_start` exactly once. ^blockadm-609o
- When caller interruption wins after the worker claim, the blocking pool shall invoke the supplied `on_cancel` hook at most once. ^blockadm-djc2
- When an operation ends before the worker claim, the blocking pool shall not invoke the supplied `on_cancel` hook. ^blockadm-t6uh
- When an ordinary Eta timeout interrupts a fail-fast blocking operation, the blocking pool shall apply the same worker-claim ownership rules as caller interruption. ^blockadm-65or
- While a claimed callback remains physically active, the blocking pool shall keep its worker slot occupied after caller interruption or detachment. ^blockadm-kytq
- When a physically active callback completes or fails, the blocking pool shall release its worker slot exactly once. ^blockadm-80hn
- While the `Drain` shutdown policy applies, when shutdown follows fail-fast admission but precedes the worker claim, the blocking pool shall run the admitted callback. ^blockadm-lavc
- While the `Drain` shutdown policy applies, when shutdown begins, the blocking pool shall run active callbacks to physical completion. ^blockadm-p8m2
- While the `Drain` shutdown policy applies, when shutdown begins, the blocking pool shall run admitted queue entries to physical completion. ^blockadm-31qp
- While the `Drain` shutdown policy applies, when shutdown begins, the blocking pool shall interrupt admission waiters without running their callbacks. ^blockadm-pa7p
- While the `Detach_started` shutdown policy applies, when shutdown precedes the worker claim for a fail-fast operation, the blocking pool shall return `Not_run Shutting_down`. ^blockadm-x2xx
- While the `Detach_started` shutdown policy applies, when shutdown precedes the worker claim for a fail-fast operation, the blocking pool shall prevent the callback from starting. ^blockadm-z87i
- When shutdown prevents an admitted callback from reaching the worker claim, the blocking pool shall release its reserved admission state exactly once. ^blockadm-ccmc
- While the `Detach_started` shutdown policy applies, when shutdown begins, the blocking pool shall interrupt admitted queue entries without running their callbacks. ^blockadm-cjsj
- While the `Detach_started` shutdown policy applies, when shutdown begins, the blocking pool shall interrupt admission waiters without running their callbacks. ^blockadm-17n6
- If ordinary `run` or `run_result` begins after pool shutdown, then the operation shall return interruption. ^blockadm-okes
- If ordinary `run` or `run_result` begins after pool shutdown, then the blocking pool shall not run the callback. ^blockadm-8a7k
- `Eta_blocking.Pool.stats.waiting` shall report the number of ordinary blocking operations that are waiting for admission. ^blockadm-s15s
- `Eta_blocking.Pool.stats.active` shall report worker slots reserved for admitted callbacks that have not reached physical completion. ^blockadm-9t58
- `Eta_blocking.Pool.stats.queued` shall report admitted bounded-queue entries and shall exclude admission waiters. ^blockadm-3yn4
- `Eta_blocking.Pool.stats.completed` shall count each physically completed callback exactly once. ^blockadm-86xw
- `Eta_blocking.Pool.stats.detached` shall count each claimed callback that becomes detached from its awaiting operation exactly once. ^blockadm-sqwe
- When a fail-fast operation returns `Not_run Saturated`, the blocking pool shall increment `Eta_blocking.Pool.stats.rejected` exactly once. ^blockadm-l8jp
- When a fail-fast operation returns `Not_run Shutting_down`, the blocking pool shall keep `Eta_blocking.Pool.stats.rejected` unchanged. ^blockadm-01e8
- When shutdown prevents a callback from starting, the blocking pool shall keep `Eta_blocking.Pool.stats.cancelled_before_start` unchanged. ^blockadm-680x
- When the blocking pool records saturation telemetry, it shall use the outcome value `saturated`. ^blockadm-w3od
- The blocking pool shall report distinct telemetry outcomes for saturation, shutdown, cancellation, completion, callback failure, and detachment. ^blockadm-l13j

## Verification seams

- Compile-time API tests reference the public types, constructors, operation
  signatures, configuration fields, and statistics fields.
- Deterministic blocking-runtime tests use controlled callback gates to observe
  immediate admission, saturation without queue entry, worker claim, and
  physical completion.
- Cancellation tests stop operations on each side of the worker claim and check
  callback execution, `on_cancel`, slot ownership, and
  `cancelled_before_start`.
- Shutdown tests cover `Drain` and `Detach_started` for active callbacks,
  admitted queue entries, admission waiters, and fail-fast handoff.
- Observability tests check `waiting`, `rejected`, and each telemetry outcome.
- Every test that verifies an obligation references its stable requirement ID.
