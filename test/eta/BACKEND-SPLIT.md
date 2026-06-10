# Eta Core Backend Split

`test/core_common` owns backend-agnostic primitive coverage that must run
through `Eta_eio`.
`test/runtime_common` owns backend-agnostic runtime API coverage, including
`run`, `run_exn`, cancellation-aware resource release, supervisor basics, and
runtime-contract integration.

The shared primitive coverage includes:

- Effect constructors/combinators, typed failure handling, defect/finalizer
  diagnostics, catch behavior around uncatchable defects and finalizer
  failures, backend-neutral interruption not being caught, mapped, or retried,
  runtime-contract interrupt classification, interrupt finalizer preservation,
  dependency passing, par/all/all_settled/for_each_par success and fail-fast
  behavior, virtual-clock ordering, bounded parallelism, race winner
  selection, scoped loser resource cleanup, loser finalizer diagnostics after
  race winners, timeout during loser cleanup, catch-after-finalizer ordering,
  concurrent child defect diagnostics, concurrent typed/defect catch behavior,
  par/for_each_par simultaneous typed failure aggregation,
  finalizer diagnostics during sibling cancellation,
  retry/repeat schedules and timeouts, seeded jittered retry, retry scoped
  resource cleanup,
  resource/finalizer/timeout semantics, daemon interrupt diagnostic
  suppression, simultaneous timeout/body failure preservation, cancelled body
  finalizer failure preservation, and uninterruptible virtual-clock behavior
- Mutable_ref
- Queue normal send/receive/close behavior plus Eta-timeout and backend-cancel
  receiver cleanup
- Channel normal bounded send/receive/close behavior plus Eta-timeout
  sender/receiver cleanup, backend-cancel sender/receiver cleanup, and
  cancelled blocked-sender payload release
- Semaphore validation, permit accounting, fairness, timeout cleanup,
  cancellation cleanup, cancel-after-wakeup permit reclamation, and portable
  with_permits_or_abort permit reclamation
- Pubsub broadcast, ordering, overflow, backpressure, close, scoped
  subscription cleanup, Eta-timeout receiver cleanup, backend-cancel receiver
  cleanup, and cancelled blocked-publisher payload release
- Pool basic resource lifecycle, release cleanup, health rejection, acquire
  failure cleanup, max-size admission, waiter timeout cleanup, shutdown
  waiter wake/drain behavior, waiter-before-release rejection, deadline
  timeout, active/idle close fencing, close-failure reporting, idle eviction,
  expired-idle admission cleanup, invariant failure reporting, observability,
  and Eta-timeout health-check cleanup
- Clock virtual sleep, multiple sleepers, and set_time wakeups
- Scope finalizer LIFO ordering through virtual time
- Resource manual refresh, concurrent refresh publication, auto-refresh
  scheduling, failed-refresh cache retention, loader-defect recording, and
  on_error defect recording
- Supervisor child failure observation, await propagation, cancellation
  finalizers, cancel-before-await behavior, cancel waiting for finalizers,
  background child cancellation, background child cleanup failure reporting,
  thresholds, multiple failures, and nested scopes
- Observability manual tracer spans, span metadata, status rendering, events,
  annotations, sampling, trace context propagation, in-memory tracer behavior,
  auto instrumentation, suppression, shared cancellation status,
  uninterruptible protected-child status, and fiber-local pending attrs/links
- Duration, Schedule, String_helpers, Eta_redacted, Runtime contract,
  Portable_queue, Properties, stress/resource-leak regression coverage, and
  upstream-invariant regression coverage

`test/blocking_common` owns backend-agnostic `eta_blocking` coverage that must
run through `Eta_eio`: blocking run/result/result_timeout
semantics, timeout cancellation hooks, queued-work cancellation, reject policy
accounting, started-work nonpreemption, shutdown rejection/drain behavior,
worker re-entry guards, and ordinary user exception classification.

The remaining cases in `test/eta` are Eio-specific or currently Eio-only
because they directly use `Eio.Cancel`, `Eio.Switch`, raw `Eio.Promise`,
`Eio_unix` wall-clock sleeps, or host scheduler interleavings.

The remaining Eio-only Blocking cases are native-host probes: custom Eio host
runners, Eio runner cancellation identity, heartbeat impact of direct blocking,
high-churn Eio lost-wakeup stress, raw Eio cancellation of queued/detached
workers, named-pool starvation timing, CPU anti-pattern timing, blocking
observability under Eio auto-instrumentation, and direct
`Eio.Cancel.Cancelled`/OCaml `Exit` distinction checks.

The remaining Eio-only Channel cases are raw Eio scheduler-window probes:
delivered receive cancellation requeueing, receiver overflow protection during
an unresolved delivery window, and parent switch teardown of a blocked sender.

The remaining Eio-only Effect host-runtime probes use raw Eio facilities:
fiberless host switch creation, domain-local fiberless runtime frames, raw
`Eio.Cancel.Cancelled` propagation from `Runtime.run`, finalizer behavior
during raw Eio cancellation, and concurrent interrupt aggregation through raw
Eio cancellation.

The remaining Eio-only retry/uninterruptible cases are host-runtime probes:
Eio multiple-exception conversion and a domain manager no-checkpoint race
loser.

The remaining Eio-only Supervisor case is raw Eio host behavior: scope
cancellation of unawaited children through raw Eio host cancellation.

The remaining Eio-only Observability case is raw `Eio.Cancel.Cancelled` status
classification.

Keep moving Eta-owned behavior to `test/core_common`; keep only raw
host-runtime probes in this directory.
