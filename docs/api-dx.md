# Eta API Style

This guide records the API shape supported by the current examples and DX gate.
It is evidence-backed API guidance for application-facing Eta code.

## Preferred User Shape

Use ordinary OCaml at the boundary and lift into Eta deliberately:

- `Effect.pure` for values already computed.
- `Effect.fail` for typed failures.
- `Effect.from_result` for a `result` already computed outside a synchronous
  leaf.
- `Effect.from_option` for an `option` already computed outside a synchronous
  leaf.
- `Effect.sync` for synchronous leaves where raised exceptions should be Eta
  defects and the success value is not already a `result`/`option`.
- `Effect.sync_result` for the recommended synchronous leaf that returns an
  OCaml `result` (`Ok` succeeds, `Error` is typed failure, raises stay
  defects). Prefer `[%eta.result "name" body]` when that leaf also needs a
  static span name and source location; it expands to
  `fn __POS__ __FUNCTION__ (named "name" (sync_result (fun () -> body)))`.
  Keep hand-written `named`/`fn` for `~error_pp`, dynamic names, or other
  kwargs; use `from_result` for already-computed results.
- `Effect.sync_option ~if_none` for the synchronous leaf that returns an
  OCaml `option` (`None` becomes the typed `if_none` failure; raises stay
  defects).
- `Effect.async` for one callback-shaped host operation such as an event,
  timer, promise, or C completion callback. Return its optional interruption
  canceler from registration; do not open-code runtime promises or cancellation.
- `Eta.Promise` when multiple Eta fibers need to share one backend-neutral
  one-shot `Exit.t`. It owns repeated-resolution visibility, broadcast wakeup,
  and cancelled-waiter cleanup.
- `Effect.flatten_result` for hand-rolled pipelines after any effect that
  succeeds with a `result` (not only the sync leaf).
- `Effect.yield` when an Eta workflow should cooperatively yield to the active
  runtime backend.
- `Effect.fresh` for runtime-local monotonic tokens, and `Effect.fresh_named`
  for readable runtime-local names such as `worker-7`. These values are not
  globally unique; add an application namespace for cross-runtime correlation.
- `Effect.tap` for success-side observers that should preserve the original
  value. Wrap plain synchronous observers with `Effect.sync`.
- `Effect.bind_error` for effectful typed failure recovery inside the Eta blueprint.
- `Effect.fold` for pure both-channel recovery that maps success and typed
  failure to one pure value (mirrors `Result.fold`).
- `Effect.discard` when a success value is unused but typed failures, defects,
  and cancellation must still fail the workflow.
- `Effect.ignore_errors` for best-effort effects where the success value is
  unused, typed failures should be suppressed, and defects/cancellation must
  remain visible.
- `Effect.to_result` when an Eta workflow should keep going and handle success or
  typed failure as an ordinary OCaml `result` value.
- `Effect.to_option` / `Effect.to_exit` when materializing typed failure as
  `option` or the full `Exit.t` as data.

Use syntax operators rather than explicit bind in application code:

- `let*` for dependent effect sequencing.
- `let+` for mapping a successful value.
- `and*` / `and+` for sequential product (strict left-to-right; nothing forked).
- `Effect.par` for independent concurrent effects (explicit at the call site).
- `let@` for callback-shaped lifecycle helpers such as `Effect.with_resource`.
- `Effect.all` for dynamic homogeneous lists of independent effects where
  fail-fast collection is wanted.

### Callback-shaped host APIs: `async` or `Expert.make`?

Use `Effect.async` in application code when one host registration may call
`resume` with an `Exit.t`. Registration must return promptly and may return a
canceler effect. The first call to `resume` wins; Eta runs the canceler only when
interrupted before resolution, and waits for that protected canceler to finish.
Therefore the canceler must not block indefinitely. A JS wrapper must check its
required host API and fail loudly; it must not install a polyfill.

Use `Effect.Expert.make` only in runtime packages that genuinely need the
current `Runtime_contract`, scope, runtime service, or Eta instrumentation
hooks. If a wrapper only needs “register callback, optionally unregister on
interruption,” touching `Expert.context` is the wrong boundary: use `async`.
Neither API makes blocking registration safe; move blocking work to
`Eta_blocking` instead.

### One-shot coordination: `Promise`, `async`, or `Eio.Promise`?

Use `Eta.Promise` for an Eta-owned one-shot result shared by fibers when the code
must remain portable across native and js_of_ocaml runtimes. Use `Effect.async`
to adapt one callback registration into one Eta effect; it owns the registration
canceler, while `Promise` instead allows any holder to attempt resolution and
wakes every waiter. Use `Eio.Promise` directly when the code and its lifetime are
intentionally Eio-only. Do not wrap Eio-only local coordination merely to remove
the Eio name; the portability fence is the reason for `Eta.Promise`.

Use ordinary OCaml for application services:

- Pass dependencies as function arguments, records, modules, or closures.
- Use `Effect.with_resource` only where constructing or cleaning up a service is
  effectful.
- Keep `Runtime_contract.service` and `Effect.Expert.runtime_service` for
  optional Eta packages that need backend-attached runtime services.

Use named helpers at common boundaries:

- `Effect.with_resource` for body-bounded acquire/use/release.
- `Effect.finally` for one-shot cleanup around an existing effect.
- `Effect.acquire_release` plus `Effect.with_scope` when a resource should live
  until an enclosing scope exits.
- `Eta.Schedule` policies for retry/repeat blueprints, including composed
  exponential and jittered retry schedules.
- `Effect.repeat` for scheduled unit-work recurrence.
- `Eta.Duration` helpers for typed time budgets and retry/timeout arithmetic.
- `Effect.timeout_as` for mapping timeout policy to the caller's own typed
  error row.
- `Effect.uninterruptible` only around small critical effects that must finish
  once started.
- `Eta.Random` helpers for deterministic scalar and collection draws over a
  portable seeded random token.
- `Eta.Log_level` helpers for log threshold parsing, filtering, and OTLP
  severity-number/rendering boundaries.
- `Eta.Sampler` policies for deterministic trace sampling and parent-based
  sampling decisions.
- `Eta.Trace_context.extract` plus `Effect.with_context` for inbound W3C
  propagation across service boundaries.
- `Effect.current_context` plus `Eta.Trace_context.inject` for outbound W3C
  propagation from the runtime context.
- `Effect.current_span` plus `Effect.link_span` for runtime-visible span
  relationships such as producer/consumer handoff.
- `Effect.fn __POS__ __FUNCTION__` for function-name spans with compiler source
  locations and ordinary span attributes.
- `Effect.with_error_pp` when typed failures need useful span statuses,
  exception-event messages, or rendered finalizer diagnostics.
- `[@@deriving eta_error]` from `ppx_eta` for a plain `pp_<type>` over a public,
  explicit-tag closed polymorphic error row, then explicit `?error_pp` /
  `with_error_pp` wiring.
- `Effect.name` and `Effect.collect_names` for preflight documentation of
  statically present blueprint names. This is not a runtime inventory.
- `Eta.Exit.to_result` at boundaries that intentionally accept only successful
  values and single typed failures as ordinary OCaml `result`.
- `Eta.Resource.auto` for runtime-owned cached resources with scheduled refresh.
- `Eta.Resource.failures` for Eta-owned refresh diagnostics instead of a
  caller-maintained side channel.
- `Eta.Resource.manual` and `Eta.Resource.refresh` for caller-driven cached
  resources where scheduled refresh is the wrong lifecycle.
- `Eta.Pool.with_resource` for bounded runtime-local connection/resource pools.
- `Eta.Pubsub.subscribe` with `let@` for scoped publish/subscribe subscriptions.
- `Eta.Pubsub.try_recv` for non-blocking scoped subscription polls.
- `Eta.Channel.close_effect` / `close_with_error_effect`,
  `Eta.Queue.close_effect` / `close_with_error_effect`, and
  `Eta.Pubsub.close_effect` / `close_with_error_effect` when close belongs
  inside an Eta workflow rather than immediate host code.
- `Eta.Channel.stats`, `Eta.Queue.stats`, `Eta.Pubsub.stats`, and
  `Eta.Semaphore.available` / `waiting` as direct snapshots inside workflow
  continuations; do not wrap plain snapshots in `Effect.sync`.
- `Eta.Channel.send` / `recv` for bounded same-domain handoff with close fences.
- `Eta.Channel.try_send` / `try_recv` for non-blocking bounded-channel probes
  that preserve typed close results.
- `Eta.Queue.unbounded`, `bounded`, `dropping`, and `sliding` for named queue
  policies without exposing the internal admission strategy.
- `Eta.Queue.send` / `take` for cross-domain queue handoff with close fences.
- `Eta.Queue.try_offer` / `poll` for non-blocking queue probes
  that preserve typed close results.
- `Eta.Mutable_ref.update_and_get` for application-owned shared state that
  needs atomic updates.
- `Eta.Semaphore.with_permits` for lexical permit ownership without manual
  acquire/release cleanup.
- `Effect.with_background` when a background child belongs to one lexical body.
- `Effect.daemon` plus `Runtime.drain` for runtime-owned finite background work
  that must be waited for at shutdown or in tests.
- `Eta.Supervisor.scoped { run = ... }` plus
  `Eta.Supervisor.Scope.(let*)` when child handles must stay inside a nursery.
- `Effect.is_tracing_enabled`, `Effect.annotate_all_lazy`, and
  `Effect.suppress_observability` for runtime-aware observability controls.
- `Eta.Tracer.in_memory`, `Eta.Logger.in_memory`, and `Eta.Meter.in_memory`
  for tests and bounded diagnostics without custom capability collectors.
- `Effect.metric_updates_lazy` for hot metric paths where snapshots and
  allocation should happen only when the runtime has a meter.
- `Eta_http.Server.Handler.of_sync` / `of_result` / `of_effect` for server
  handlers.
- `Eta_blocking.run_result` for blocking leaves with expected typed failures.

## Cancellation Checkpoints

Eta cancellation is cooperative. A checkpoint is a call that checks an
already-cancelled runtime context or installs a cancellation wakeup while it is
blocked. Pure effect composition and ordinary synchronous OCaml code do not
poll for cancellation between expressions.

The portable checkpoint list is:

- `Effect.yield`;
- positive `Effect.sleep` and the sleep before `Effect.delay` with the default
  live runtime clocks, including timer waits used by timeout, retry, repeat,
  schedules, and resource refresh; a custom clock inherits its own sleep
  semantics;
- a pending `Eta.Promise.await`, the pending park in `Effect.async`, and
  `Effect.never`;
- blocking handoff paths: full `Channel.send`, empty `Channel.recv`, full
  backpressure `Queue.offer`/`send`, empty `Queue.take`,
  `Queue.await_shutdown`, full backpressure `Pubsub.publish`, empty
  `Pubsub.recv`, and waiting `Semaphore.acquire`;
- actual coordination waits in parallel/race/supervisor/background operations,
  pool slot/shutdown handling, cache load coalescing, signal graph lanes,
  stream draining, and `Eta_blocking` admission or result waits.

Only the blocking path is a checkpoint. Immediate/nonblocking operations such
as `Channel.try_send`/`try_recv`, `Queue.try_offer`/`poll`,
`Pubsub.try_recv`, snapshots, a non-positive live-backend sleep, and an
immediately available handoff do not become checkpoints because a sibling path
can block.

Backend services inherit their backend's checkpoints. Native Eio operations are
cancellable where they block: accept/connect, flow reads and writes, unresolved
Eio promises, empty/full Eio streams, mutex/condition waits, positive clock
sleeps, TLS/HTTP waits, and the owner wait for a system-thread job. JS host
operations are cancellable while their `Eta_jsoo.Private.await` or
`Effect.async` continuation is pending and use the supplied host cancellation
hook, if any. Immediate I/O is not a checkpoint.

Do not use an already-settled promise as a portable explicit checkpoint: Eio's
resolved `Promise.await` fast path returns without checking cancellation, while
the js_of_ocaml await path checks before observing the settled result. Use
`Effect.yield` when an explicit portable checkpoint is required. A backend
operation that wins its wakeup race may return its committed result; pending
cancellation remains visible to a later checkpoint.

`Effect.async` registration is protected through return, and its interruption
canceler is protected while Eta waits for it. Eta finalizers and `Effect.finally`
cleanup also run under cancellation protection. Those cleanup regions may
block, but they do not restore parent cancellation.

### Cancellation masks and restoration

`Effect.uninterruptible body` defers parent cancellation for `body`.
`Effect.interruptible blocked` restores the parent cancellation state of the
dynamically nearest enclosing mask while `blocked` runs. Outside a mask it is
identity. Restoration moves the current runtime fiber; it does not fork, so
fiber identity, runtime-local bindings, tracing, and fiber-reentrant protocols
are preserved.

Restoration listens to both the mask-entry parent and the entry-time current
cancellation context. This matters when same-fiber code creates a descendant
`cancel_sub` inside the mask before entering `interruptible`: cancellation of
either context wakes a restored block. When the sources compete, the reason from
the first cancellation call executed wins, and delivery is observed at most
once.

Masks cover children, but restoration is fiber-local. A child forked inside
`uninterruptible` inherits the mask through cancellation-context lineage on
native Eio and protection depth on js_of_ocaml; it does not inherit its parent's
restore closure. Therefore `interruptible` in that child is identity and the
child remains masked against parent cancellation. Direct failure of the child's
own structured scope still interrupts it, preserving fail-fast. Daemons inherit
neither restoration nor cleanup-forbidden state and start independently
unmasked.

Masks stack and the innermost mask wins. In particular,
`uninterruptible (interruptible (uninterruptible body))` has the cancellation
behavior of `uninterruptible body`: the inner mask supersedes the outer
restoration. Repeated `interruptible` inside an already restored region is
identity. A cancellation already pending at restoration entry, one arriving at
a checkpoint in the restored body, or one pending at its successful exit is
delivered without a lost wakeup and is observed at most once.

Restoration is forbidden while finalizers, `finally` cleanup, and asynchronous
cancelers run. These cleanup paths stay protected even when inherited from an
enclosing mask; allowing restoration there would permit re-entrant cancellation
to abort cleanup whose completion Eta already promises to await.

## What The Examples Prove

The guarded gate in `test/api_dx/api_dx_examples.ml` covers resource workflow,
runtime-owned cached resources, scoped resource handles, retrying external
calls, ordinary service composition, typed failure recovery, pure typed failure recovery, best-effort typed failure suppression, typed failure materialization as `result`, backend-neutral cooperative yielding, success-value
projection, pure validation lifting, synchronous defect capture, composed retry schedules, stream
transforms, success-side observation, synchronous success-side observation, scheduled unit recurrence, fail-fast list
collection, bounded channels, non-blocking channel probes, effectful handoff
close, direct handoff snapshots, unbounded queues,
non-blocking queue probes, shared mutable state, typed duration budgets, typed timeout policies,
cancellation-protected critical effects, log-level policies and severity
boundaries, deterministic scalar and collection random helpers, HTTP handlers,
bounded batch concurrency, static blueprint name inspection, source-location
function spans, typed-error rendering, racing mirrors, typed-error boundaries,
one-shot cleanup, lexical semaphore permits, abortable admission control, tests, small CLI/business logic,
runtime-local pools, scoped pubsub subscriptions, non-blocking pubsub polls,
trace sampling, trace context propagation, trace context injection, blocking typed leaves, runtime exit/cause boundaries, runtime
execution boundaries, observability, observability controls,
observability sinks, lazy metric batching, background lifecycle, runtime-owned
daemon draining, supervised nurseries, runtime-owned resource failure
diagnostics, caller-driven manual resource refresh, and span linking.
The proposed snippets remove explicit `Effect.bind` from all sixty-four areas.
`let*` remains where code really sequences dependent effects or ordered

observability signals; `and*` is the rule for products that must stay
sequential (this file's formerly-concurrent uses all moved to `Effect.par`);
`Effect.par` remains where independent foreground effects run concurrently;
`let@` remains where code marks lexical resource lifetime.
`Supervisor.Scope.(let*)` remains inside the supervisor example because child
handles live only inside the nursery scope.

`test/api_dx/api_dx_surface.ml` also scans the promoted example files, package
READMEs, and preferred user-facing docs so explicit `Effect.bind` / `(>>=)` does
not return to the recommended surface by accident.

The runnable examples under `examples/` use real public modules:

- `quickstart.ml`
- `fold_recovery.ml`
- `validation_boundary.ml`
- `sync_defect_boundary.ml`
- `resource_retry.ml`
- `retry_schedule.ml`
- `repeat_heartbeat.ml`
- `cached_resource.ml`
- `manual_resource_refresh.ml`
- `scoped_resource.ml`
- `service_composition.ml`
- `source_locations.ml`
- `tap_success.ml`
- `map_projection.ml`
- `stream_decode.ml`
- `batch_concurrency.ml`
- `all_health_checks.ml`
- `blueprint_names.ml`
- `bounded_channel.ml`
- `channel_probe.ml`
- `unbounded_queue.ml`
- `queue_probe.ml`
- `mutable_ref_state.ml`
- `deterministic_random.ml`
- `duration_budget.ml`
- `timeout_policy.ml`
- `uninterruptible_commit.ml`
- `error_rendering.ml`
- `log_level_policy.ml`
- `trace_sampling.ml`
- `trace_context_boundary.ml`
- `span_linking.ml`
- `exit_cause_boundary.ml`
- `finally_cleanup.ml`
- `runtime_boundary.ml`
- `race_mirror.ml`
- `typed_error_boundary.ml`
- `admission_control.ml`
- `semaphore_permits.ml`
- `connection_pool.ml`
- `pubsub_subscription.ml`
- `pubsub_poll.ml`
- `http_handlers.ml`
- `cli_business.ml`
- `blocking_result.ml`
- `supervisor_scope.ml`
- `background_lifecycle.ml`
- `daemon_drain.ml`
- `observability.ml`
- `observability_controls.ml`
- `observability_sinks.ml`
- `metric_batching.ml`
- `workflow_test.ml`

Those files contain no explicit `Effect.bind` or `(>>=)`.

## What Is Not Proven Removable

`Effect.bind` and `(>>=)` are not recommended in user-facing examples, but they
remain the primitive sequencing surface under `Eta.Syntax`, internal modules,
and advanced combinator code.

Public interface docs now spell this out directly: `Effect.bind`,
`Effect.(>>=)`, and `Supervisor.Scope.bind` are primitive/advanced surfaces;
`Eta.Syntax.(let*)` and `Supervisor.Scope.(let*)` are the preferred
user-facing spellings.

`Effect.acquire_use_release` is doc-dominated by `Effect.with_resource` for
new application code. It still names the bracket operation directly and remains
public until a later pass proves that retaining both names makes the API less
clear.

`Effect.tap` is not replaced by spelling `bind` plus `map` at every
success-observation site. Use it when an effectful observer should run on
success and the original success value should continue unchanged. Use `let*`
when later work actually depends on the observer's result.

`Effect.tap` is effectful by design. The observer's success value is ignored,
but its typed failure, defect, interruption, resource lifecycle, and
observability still matter. For a plain synchronous observer, wrap it explicitly:
`Effect.tap (fun value -> Effect.sync (fun () -> observe value))`.

`Eta.Syntax.(let+)` is not replaced by spelling `bind` plus `pure` for ordinary
success-value projection. Use `let+` when the continuation is pure; use `let*`
when the continuation returns another effect.

`Effect.bind_error` is not replaced by moving typed failures into successful
`result` values and then branching with `bind`. Keep expected domain failures
in Eta's typed error channel and recover them with `bind_error` or `fold`
depending on whether recovery is effectful or pure. Defects, interruptions,
and finalizer diagnostics remain outside typed recovery.

`Effect.fold` is not a replacement for `Effect.bind_error`. Use `fold` when both
channels collapse to a pure value; use `bind_error` when recovery itself is an
Eta effect.

`Effect.discard` is not a recovery combinator: every cause still fails.
`Effect.ignore_errors` is not a replacement for `Effect.bind_error` or
`Effect.fold`. Use it only for best-effort effects whose success value is unused and whose
typed failures are intentionally suppressed. It does not handle defects, interruption, or
finalizer diagnostics.

`Effect.to_result` is not a replacement for typed recovery. Use `bind_error` or
`fold` when a typed failure should choose a recovery path and stay in Eta's
typed error model. Use `to_result` only when both success and typed failure are
ordinary data for the next workflow step. It does not capture defects,
interruption, or finalizer diagnostics.

`Effect.all` is not replaced by recursive `bind` / `map` loops over a list of
effects. Use `and*` for a small fixed set of differently typed effects that must
sequence left-to-right; use `Effect.par` for a fixed concurrent product;
`Effect.map_par f inputs` when the workflow maps over inputs concurrently; and
`all_settled` when every child outcome is needed instead of fail-fast
collection. `map_par` collects in input order and starts at most eight mapper
fibers by default; pass `~max_concurrent` for a different positive cap. Omission
does not mean unbounded concurrency.

`Effect.acquire_release` and `Effect.with_scope` are not replaced by
`Effect.with_resource`. They are needed for resources that intentionally live
until a surrounding runtime, supervisor, daemon, or scope boundary exits.

For a fixed set of resources, default to a nested `Effect.with_resource` ladder:

```ocaml
let open Eta.Syntax in
let@ pool =
  Effect.with_resource ~acquire:Pool.connect ~release:Pool.close
in
let@ cache =
  Effect.with_resource ~acquire:Cache.connect ~release:Cache.close
in
serve pool cache
```

The structure makes lifecycle semantics visible: acquisition is sequential,
the inner resource releases before the outer resource, and both releases run
when their enclosing body exits.

When acquisition concurrency matters, use one `Effect.with_scope`, acquire the
independent descriptions with `Effect.map_par` (or `Effect.all` for an existing
homogeneous list), and register each completed resource in the owner scope with
`Effect.acquire_release`. Parallel combinators give each child its own finalizer
scope, so the bridge must perform owner registration explicitly. **This bridge
is advanced**: it uses `Effect.Expert.make`/`eval`, the runtime-package
extension point, not ordinary application API — most programs should prefer the
`with_resource` ladder above. For example, four homogeneous database shards can
share one owner scope:

```ocaml
let acquire_into scope ~acquire ~release =
  Effect.Expert.make @@ fun child ->
  match Effect.Expert.eval child acquire with
  | Exit.Error _ as error -> error
  | Exit.Ok resource ->
      Effect.Expert.eval scope
        (Effect.acquire_release ~acquire:(Effect.pure resource) ~release)

let with_shards configs body =
  Effect.with_scope
    (Effect.Expert.make @@ fun scope ->
     Effect.Expert.eval scope
       (Effect.map_par
          (fun config ->
            acquire_into scope ~acquire:(Db.connect config) ~release:Db.close)
          configs
        |> Effect.bind body))
```

The shard acquisitions run concurrently. A failed shard cancels acquisitions
still in progress; connections already registered are closed once in reverse
successful acquisition order as the scope exits.

`Effect.finally` is not replaced by hand-written `bind_error` cleanup. Manual
cleanup around typed success/failure paths misses defects and cancellation, and
does not preserve cleanup failures with Eta's finalizer/suppressed-cause
semantics. Use `finally cleanup body` for one-shot cleanup around an existing
effect. Use `with_resource` when cleanup depends on a newly acquired resource,
and `acquire_release` / `with_scope` when a resource should live until a wider
scope boundary.

`Effect.sync` is the synchronous defect boundary. Use it when exceptions should
be unchecked defects and the success value is not already a `result`/`option`.
When the leaf operation returns expected typed failures as `result`, prefer
`Effect.sync_result f`. It is exactly `sync f |> flatten_result`: `Ok` succeeds,
`Error` is typed failure, and ordinary exceptions remain `Cause.Die`. When the
leaf returns an `option`, prefer `Effect.sync_option ~if_none f`: `Some`
succeeds, `None` is the typed `if_none` failure, and ordinary exceptions remain
`Cause.Die`. The sync-defect example keeps unexpected exceptions in
`Cause.Die`.

Named result leaves: `[%eta.result "name" body]` is the leaf-boundary sugar for
`fn` + `named` + `sync_result`. Convert only IO/trust leaves with a static span
name; pure glue and sites needing `~error_pp` stay explicit.

`Effect.yield` is not replaced by `Effect.sync Eio.Fiber.yield`. Use `yield`
when a blueprint needs a cooperative scheduling point; it delegates to the
active runtime backend instead of hard-coding Eio in user workflow code.

`Effect.from_result` is the typed-failure lifting boundary. Use it directly for
pure validation or parsing results already computed outside a synchronous leaf.
For a synchronous leaf that returns `result`, use `Effect.sync_result`. Keep
`Effect.flatten_result` when an arbitrary effect succeeds with a nested
`result` that still needs flattening.

`Effect.from_option` is the option analogue for already-computed lookup or
extraction results where `None` should become a typed failure. For a
synchronous leaf that returns `option`, use `Effect.sync_option ~if_none`.
Neither is a fallback mechanism and neither catches exceptions.

Eta does not add `Layer`, `Context`, `Tag`, `Effect.provide`, or an environment
type for application services. The service-composition example shows ordinary
function arguments are shorter and statically clearer than a dynamic service
bag. Runtime services remain the optional-package hook for backend-attached
capabilities such as blocking pools or HTTP clients; they are not a general
application dependency-injection channel.

`Schedule` is not replaced by recursive retry loops or ad hoc sleep calls. Its
two-parameter type [('input, 'output) Schedule.t] owns retry/repeat policy
description, bounded recurrence, composition, exponential and linear backoff,
deterministic jitter through the runtime random capability, and a stateful
driver for interpreters. Use
`Effect.retry ~schedule:policy ~while_:retryable effect` instead of spelling
retry lifecycle in application code. `retry` currently retries only a bare
`Cause.Fail`; it does not inspect composite typed causes.

Use
`Effect.retry_or_else ~schedule:policy ~while_:retryable ~or_else:fallback effect`
when exhaustion or predicate rejection should change the typed error channel.
Unlike `retry`, it handles catchable composite causes and gives the first typed
failure to the fallback. This is a current semantic difference, not a preferred
property of one shape. The fallback receives no schedule output when the first
failure is rejected before a step, and the latest or terminal output after
steps have run.

`Effect.repeat ~schedule:policy effect` is not replaced by hand-written recursion over
`Schedule.start` and `Schedule.next`. The manual shape is useful for
interpreters; every schedule can be stepped directly after the hook channel's
deletion. Application code should describe a scheduled unit effect and let Eta
drive the policy, sleeps, cancellation, and iteration failure behavior.

### Observing scheduled work

Observe the operation, not the schedule policy:

- For `Effect.retry`, `retry_or_else`, and `repeat`, instrument the source effect
  before passing it to the operation. This sees every source attempt, including
  the initial attempt.
- For `Resource.auto`, instrument `load`. Use an application-owned counter when
  seed and refresh loads need different labels.
- For `Stream.retry`, put `Stream.tap_error` on the source before `Stream.retry`,
  or instrument the source directly. A `tap_error` outside `retry` sees only the
  final failure. For `Stream.repeat`, instrument the source or use `Stream.tap`
  to observe emitted values. For `Stream.schedule` and `Stream.from_schedule`,
  use `Stream.tap` to observe emitted values.
- In a custom interpreter, observe immediately around `Schedule.step`.

For example, put attempt observation inside the source effect so failures and
the initial attempt are visible:

```ocaml
let attempts = ref 0 in
let observed = ref [] in
let request =
  Effect.sync (fun () ->
      incr attempts;
      observed := !attempts :: !observed)
  |> Effect.bind (fun () -> request_once)
in
Effect.retry ~schedule:(Schedule.recurs 2) ~while_:retryable request
```

These recipes are intentionally **not parity replacements for schedule taps**.
They cannot observe schedule-local boundaries: terminal non-emitted
inputs/outputs, policy-generated outputs, policy evaluation before driver-state
publication, hook failure or cancellation as an advancement veto, or
branch/phase-local events inside one composed step. Eta deleted that capability
because no shipped producer or external adoption demonstrated demand for it.

`Duration` is not replaced by raw millisecond integers or seconds floats. The
typed value keeps unit conversion, non-negative clamping, bounded arithmetic,
scaling, comparison, formatting, and Eio/runtime sleep bridging in one small
surface. The duration example is one line longer than raw integer math; the
accepted reason is preventing unit drift and keeping schedule, timeout, delay,
and test-clock code on the same time representation.

`Effect.timeout_as` is not replaced by hand-written `Effect.race` plus
`Effect.delay`. The manual shape can express a competition, but it pushes
timeout mapping, losing-branch cancellation, cleanup waiting, and
finalizer/suppressed-cause behavior onto every caller. `timeout_as` keeps the
timeout in the caller's typed error row; `Effect.timeout` remains the shorter
form when a raw `` `Timeout`` variant is the desired row member.

`Effect.uninterruptible` is not replaced by a naked `Effect.race` branch or by
cleanup code. It is the explicit marker that parent cancellation must be
deferred while a small critical effect runs. It does not turn cancellation into
a typed failure and should not be used as a blanket around long-running work.

`Log_level` is not replaced by raw strings, integer ranks, or raw OTLP severity
numbers. It owns case-insensitive threshold parsing, `All` / `Off` threshold
semantics, level comparison, rendering, and OTLP severity-number mapping. Raw
strings and integers are still boundary formats; keep them at configuration or
export boundaries and convert to `Log_level.t` before policy decisions.

`Random` is not replaced by naked `Capabilities.random_float` math or
`Stdlib.Random`. Eta's helpers are deterministic draws over the same portable
random token that runtime schedules use, so tests and runtime configuration can
replay random-dependent behavior from an explicit seed. This includes collection
helpers such as `shuffle`, `weighted_choice`, and `sample`, which avoid
hand-written indexing, sorting, and weight accumulation around raw floats.

`Sampler` is not replaced by ad hoc trace-id hashing in applications. It names
the runtime sampling policy, clips ratio bounds, and preserves parent-based
decisions in the same shape that `Runtime.create ?sampler` interprets for span
creation.

`Trace_context` is not replaced by manual `traceparent` substring slicing or
`Effect.with_external_parent`. It validates W3C propagation headers, preserves
sampled flags, tracestate, and baggage, and feeds the same context into
`Effect.with_context` that the runtime uses for parent-based sampling and span
parenting. `with_external_parent` remains only the compatibility shape when a
boundary truly has just trace/span IDs.

`Trace_context.inject` and `Effect.current_context` are not replaced by
hand-written outbound `traceparent`, `tracestate`, and `baggage` strings. Read
the runtime context inside the blueprint and inject it at the outbound boundary
so W3C formatting stays in Eta's propagation helper.

`Effect.link_span` is not replaced by annotating spans with `linked.trace_id`
strings. Use `Effect.current_span` to read the active runtime span when a
producer needs to hand off context, and `link_span` to record the relationship
as a first-class tracer link on the consumer span.

`Effect.fn` is not replaced by manual `Effect.named` plus a hand-formatted
`loc` attribute. Use `Effect.fn __POS__ __FUNCTION__ body` for normal
function-name spans: the compiler supplies the function name and source
position, while the helper still accepts span kind, `?error_pp`, and attrs.
`Effect.here_attr` remains the lower-level wrapper primitive when a helper needs
to pass `__POS__` through unchanged without choosing a new span name.

`Effect.with_error_pp` is not replaced by converting typed failures into
exceptions or strings at the source. The typed error value stays in the
`Effect.t` error channel; the printer is scoped diagnostic policy for
observability span status, exception-event messages, and rendered finalizer
diagnostics. Output is rendered at most once per span status or exception
event; the printer must be total, and a raising `error_pp` becomes a defect
through the ordinary capture path. Use the `?error_pp` argument on `named` or
`fn` when one span owns the printer; use `with_error_pp` when a subtree,
resource, or finalizer path should share it. Omission keeps the default
`"<typed failure>"` status text.

`[@@deriving eta_error]` makes meaningful typed-failure telemetry the short
path without changing that explicit policy boundary. For a public, explicit-tag
closed polymorphic-variant alias, the structure generator defines a plain
`pp_<type>` match and the signature generator emits
`val pp_<type> : Format.formatter -> <type> -> unit`; put the deriving annotation
on the declaration in both the `.ml` and `.mli`. Nullary tags and
`string`, `int`, `int64`, `float`, or `bool` payloads are built in; another
single payload must name its formatter with `[@eta.render f]`. Unsupported
payloads, nominal variants, private aliases, open or restricted rows, inherited
rows, and tuple payloads fail at PPX time—there is no generated `<payload>`
fallback. Tag text is lowercase with underscores preserved, so renaming a constructor changes
stable span-status strings and may require dashboard changes. The deriver does
not wire itself into spans: pass `pp_error` to `named` / `fn` with `~error_pp`,
or use `with_error_pp pp_error` for one explicit subtree. A raising derived or
custom payload printer follows the same contract and becomes a defect.

`Effect.name` and `Effect.collect_names` are not replaced by a parallel manual
registry of expected workflow names. They inspect the existing effect
description before interpretation and are useful for documentation, preflight
checks, and diagnostics. They are intentionally not a complete runtime
inventory: names created by continuation-producing nodes such as `bind`,
`bind_error`, `map_par`, or supervisor bodies are not forced just to
inspect them.

`Exit` and `Cause` are not replaced by OCaml `result` or exceptions.
`Exit.to_result` is intentionally partial: it converts successful values and a
single typed `Cause.Fail`, but defects, interruption, concurrent/sequential
causes, finalizer failures, and suppressed cleanup failures have no faithful
`result` representation. Use `Exit.to_result` only at process, test, or adapter
boundaries that deliberately collapse to `result`; otherwise keep the full
`Exit.Error cause` and render or inspect it with `Cause.pp`.

`Runtime.run` is not replaced by `Runtime.run_exn`. Use `run` at application
and adapter boundaries when typed failures, defects, interruption, and cleanup
diagnostics need to remain inspectable as `Exit`. `run_exn` remains a
convenience for tests and top-level programs that cannot recover; it preserves
successful values but raises on non-success, collapsing typed failures into a
rendered exception path.

`Effect.metric_update` is not replaced by `Effect.metric_updates_lazy`. Use
single updates when emitting one observation. Use `metric_updates` or
`metric_updates_lazy` when a hot path emits a group of related observations and
should share one runtime timestamp or avoid snapshot/allocation work when no
meter is installed.

`Effect.is_tracing_enabled`, `Effect.annotate_all_lazy`, and
`Effect.suppress_observability` are not replaced by passing runtime flags
through application code. They let the same blueprint decide at interpretation
time whether tracing work is useful and whether an observer/exporter subtree
must avoid recursively observing itself. The controls example is longer than an
external boolean sketch; the accepted reason is preserving runtime ownership of
observability state.

`Tracer.in_memory`, `Logger.in_memory`, and `Meter.in_memory` are not replaced
by bespoke capability objects in tests. The built-in sinks provide synchronized
collection, `as_capability` adapters for runtime creation, dumps for
assertions, and `Tracer.retain_recent` for bounded diagnostics.

`Resource.auto` is not just `with_background` around a ref. It owns the
runtime-scoped refresh loop, preserves the last good value after refresh
failure, records typed failures and defects, and lets callers inspect
`Resource.failures`. `Resource.manual` and `Resource.refresh` remain the
caller-driven shape when scheduled refresh is the wrong lifecycle: refresh
failures return through the caller's typed channel and the last good value stays
published.

`Resource.failures` is not replaced by an `~on_error` callback that appends to a
caller-owned ref. `on_error` is a side-effect hook for immediate observation;
`Resource.failures` is the resource-owned diagnostic ledger that keeps typed
refresh failures and defects in Eta's cause model.

`Pool.with_resource` is not just `Effect.with_resource` around an `acquire`
function. `Pool.create` owns bounded checkout, idle reuse, close accounting,
shutdown, stats, cancellation cleanup, and optional health/eviction policy.
Plain resource brackets remain correct for one-shot resources; pools are for
runtime-local values intentionally reused across operations.

`Pubsub.subscribe` is not just a callback inconvenience. The callback carries a
scoped subscription lifetime: when the body succeeds, fails, or is cancelled,
the subscription is removed and retained messages can be released. Prefer
`let@ sub = Pubsub.subscribe hub in ...` for application subscribers; naked
`publish`/`recv` remain the low-level message operations inside that scope.
The pubsub-poll bucket keeps `Pubsub.try_recv` visible for non-blocking reads
inside a scoped subscription; hub-level `Pubsub.stats` cannot tell whether a
particular subscription cursor currently has a message or a typed close result.

`Channel` is not replaced by `Queue`, `Pubsub`, or `Semaphore`. It owns bounded
same-domain handoff: senders wait when capacity is full, cancellation removes
waiter slots, buffered values drain after close, and clean or typed close is
reported after the buffer is empty. Use it when backpressure is the contract.
The channel-probe bucket keeps `Channel.try_send` and `Channel.try_recv`
visible for non-blocking probes; a caller-maintained `Channel.stats` capacity
check cannot preserve the typed close reason and still races the real channel
state.
The handoff-close bucket keeps `Channel.close_effect`,
`Channel.close_with_error_effect`, `Queue.close_effect`,
`Queue.close_with_error_effect`, `Pubsub.close_effect`, and
`Pubsub.close_with_error_effect` visible because close is a workflow action
when it is sequenced after sends or publishes; raw immediate close functions
remain available for host callbacks and low-level internals.
The handoff-snapshot bucket does not justify adding `stats_effect` wrappers:
`Channel.stats`, `Queue.stats`, `Pubsub.stats`, and semaphore counters are
plain snapshots. Read them directly inside a `let*` continuation and lift the
combined value once with `Effect.pure` when the surrounding shape still needs
an effect.

`Queue` is not replaced by `Channel`, `Pubsub`, or `Semaphore`. It owns
same-domain producer/consumer handoff with named admission policies:
`unbounded`, `bounded` backpressure, `dropping`, and `sliding`. Receivers wait
only when the buffer is empty, cancellation removes waiter slots, and clean or
typed close is reported after buffered values drain. Use it when queue policy,
stream handoff, or producer/consumer views are the contract.
The queue-probe bucket keeps `Queue.try_offer` and `Queue.poll` visible for
non-blocking probes; a caller-maintained `Queue.stats` check cannot preserve
the typed close reason and still races the real queue state.

`Mutable_ref` is not replaced by `Effect`, `Resource`, or a naked `Atomic.t`.
It is application-owned shared state, not a lifecycle manager and not a service
environment. Use it when a synchronous leaf needs a named cell with CAS-backed
`update` / `update_and_get`; use higher-level Eta primitives when lifetime,
cleanup, backpressure, or subscription ownership is the contract.

`Semaphore.acquire` and `Semaphore.release` are not preferred for ordinary
application admission control. Use `Semaphore.with_permits` for lexical permits
and `Semaphore.with_permits_or_abort` when permit acquisition races an abort
signal. The raw operations remain for custom protocols, tests, and internals
such as pools.

`Eta_blocking.result` and `Eta_blocking.result_timeout` remain short aliases.
New examples prefer `Eta_blocking.run_result` and `run_result_timeout` because
those names make the blocking boundary explicit.

`Supervisor.scoped { run = ... }` remains the preferred nursery entry shape when
code needs child handles. The body record is not just syntax noise: it carries a
rank-2 scope token so child handles cannot escape their nursery. Prefer
`Effect.with_background` when the body does not need a child handle.

`Effect.daemon` is not replaced by `Effect.with_background`. Use
`with_background` for body-owned work that must be cancelled when the body
finishes. Use `daemon` only for runtime-owned finite infrastructure work, and
`Runtime.drain` before shutdown or in tests that assert daemon effects.

`Eta_eio.Runtime.create` remains explicit in application examples. The current
examples use the runtime value to own clocks, sleep/random capabilities,
tracer/logger/meter choices, daemon draining, and blocking pools. A one-shot
runner would hide that ownership and would require a different package boundary
if it also owned `Eio_main.run`. `eta_utop` already provides that convenience
tradeoff for interactive sessions.

## Effect Surface Map

`Effect.mli` exposes more than the minimum application style because Eta owns
effect description, interpretation, structured concurrency, resource lifetime,
and observability. The current evidence supports this split:

| Surface | Examples |
| --- | --- |
| Preferred application API | `pure`, `fail`, `from_result`, `from_option`, `flatten_result`, `sync`, `sync_result`, `sync_option`, `async`, `yield`, `tap`, `bind_error`, `fold`, `discard`, `ignore_errors`, `to_result`, `to_option`, `to_exit`, `map_par`, `retry`, `retry_or_else`, `repeat`, `delay`, `timeout_as`, `uninterruptible`, `interruptible`, `all`, `with_resource`, `with_scope`, `finally`, `with_background`, `Eta.Schedule`, `Eta.Duration.ms`, `Eta.Duration.seconds`, `Eta.Log_level.of_string`, `Eta.Log_level.is_enabled`, `Eta.Log_level.to_string`, `Eta.Log_level.to_otel_severity`, `Eta.Log_level.of_otel_severity`, `Eta.Log_level.pp`, `Eta.Random.int_in_range`, `Eta.Random.float_in_range`, `Eta.Random.bool`, `Eta.Random.shuffle`, `Eta.Random.weighted_choice`, `Eta.Random.sample`, `Eta.Sampler.ratio`, `Eta.Sampler.parent_based`, `Eta.Trace_context.extract`, `Eta.Trace_context.inject`, `Effect.with_context`, `Effect.current_context`, `Effect.current_span`, `Effect.link_span`, `Eta.Runtime.run`, `Eta.Runtime.drain`, `Eta.Exit.to_result`, `Eta.Resource.auto`, `Eta.Resource.manual`, `Eta.Resource.refresh`, `Eta.Resource.get`, `Eta.Resource.failures`, `Eta.Pool.create`, `Eta.Pool.with_resource`, `Eta.Pool.shutdown`, `Eta.Pubsub.subscribe`, `Eta.Pubsub.try_recv`, `Eta.Pubsub.stats`, `Eta.Pubsub.close_effect`, `Eta.Pubsub.close_with_error_effect`, `Eta.Channel.send`, `Eta.Channel.recv`, `Eta.Channel.try_send`, `Eta.Channel.try_recv`, `Eta.Channel.stats`, `Eta.Channel.close_effect`, `Eta.Channel.close_with_error_effect`, `Eta.Queue.unbounded`, `Eta.Queue.bounded`, `Eta.Queue.dropping`, `Eta.Queue.sliding`, `Eta.Queue.send`, `Eta.Queue.take`, `Eta.Queue.try_offer`, `Eta.Queue.poll`, `Eta.Queue.stats`, `Eta.Queue.close_effect`, `Eta.Queue.close_with_error_effect`, `Eta.Semaphore.with_permits`, `Eta.Semaphore.with_permits_or_abort`, `Eta.Semaphore.available`, `Eta.Semaphore.waiting`, `Eta.Mutable_ref.update_and_get`, `Eta_blocking.run_result`, `named`, `fn`, `with_error_pp`, `log`, `event`, `with_result_attrs`, `annotate_all_lazy`, `is_tracing_enabled`, `suppress_observability`, `metric_update`, `metric`, `metric_updates`, `metric_updates_lazy`, `Eta.Tracer.in_memory`, `Eta.Logger.in_memory`, `Eta.Meter.in_memory` |
| Semantic capabilities to keep visible | concurrency (`race`, `par`, `all`, `all_settled`, `map_par`), retry/repeat policies (`Schedule.recurs`, `Schedule.exponential`, `Schedule.jittered`, `Schedule.start`, `Schedule.next`), typed time values (`Duration.ms`, `Duration.seconds`, `Duration.add`, `Duration.subtract`, `Duration.times`, `Duration.scale`, `Duration.clamp`, `Duration.between`, `Duration.to_ms`, `Duration.pp`), typed log levels (`Log_level.of_string`, `Log_level.is_enabled`, `Log_level.to_string`, `Log_level.to_otel_severity`, `Log_level.of_otel_severity`, `Log_level.pp`), deterministic random (`Capabilities.random_of_seed`, `Capabilities.random_set_seed`, `Random.int_in_range`, `Random.float_in_range`, `Random.bool`, `Random.shuffle`, `Random.weighted_choice`, `Random.sample`), trace sampling (`Sampler.always_on`, `Sampler.always_off`, `Sampler.ratio`, `Sampler.parent_based`, `Sampler.sample`), trace propagation (`Trace_context.extract`, `Trace_context.inject`, `Trace_context.make`, `Effect.with_context`, `Effect.current_context`, `Effect.current_span`, `Effect.link_span`), source locations (`Effect.fn`, `Effect.here_attr`), typed error rendering (`Effect.with_error_pp`, `?error_pp` on `named` / `fn`), runtime outcomes (`Runtime.run`, `Runtime.run_exn`, `Runtime.drain`, `Exit.to_result`, `Exit.pp`, `Cause.pp`, `Cause.Finalizer`, `Cause.Suppressed`), bounded handoff (`Channel.create`, `Channel.send`, `Channel.recv`, `Channel.try_send`, `Channel.try_recv`, close/error propagation), queue handoff (`Queue.unbounded`, `Queue.bounded`, `Queue.dropping`, `Queue.sliding`, `Queue.send`, `Queue.take`, `Queue.try_offer`, `Queue.poll`, producer/consumer views, close/error propagation), shared state (`Mutable_ref.make`, `Mutable_ref.update`, `Mutable_ref.update_and_get`, `Mutable_ref.get_and_set`), cached resources (`Resource.auto`, `Resource.manual`, `Resource.refresh`, `Resource.failures`), pools (`Pool.create`, `Pool.with_resource`, `Pool.shutdown`, `Pool.stats`), pubsub (`Pubsub.subscribe`, `Pubsub.publish`, `Pubsub.recv`, `Pubsub.try_recv`, close/error propagation), admission control (`Semaphore.with_permits`, `Semaphore.with_permits_or_abort`), supervised nurseries (`Supervisor.scoped`, `Supervisor.Scope`), wider resource scopes (`with_scope`, `acquire_release`, `daemon`), interruption/cleanup/time (`uninterruptible`, `interruptible`, `finally`, `timeout`, `repeat`), typed error transforms (`map_error`, `tap_error`), observability context/attributes/control/sinks/metric batching |
| Diagnostic/preflight surface | `name`, `collect_names` |
| Low-level or advanced surface | `bind`, `(>>=)`, `seq`, `concat`, `acquire_use_release`, `supervisor_*` builders, `Expert`, runtime-package service hooks (`Runtime_contract.create_service_key`, `Runtime_contract.Service`, `Effect.Expert.runtime_service`) |

The diagnostic row is not first-contact workflow style, but it is promoted for
preflight documentation and tests that inspect an existing effect description.
The low-level group is not a deletion list. It is a doc-demotion list: these
names should not be the first way users learn Eta, but they remain justified as
primitive, bridge, or implementation support until stronger evidence says
otherwise. The detailed audit lives in
`.scratch/research/evidence/eta_research/api_dx/effect_surface.md`.

The no-explicit-bind surface scanner intentionally excludes archived research
notes, audit logs, probe writeups, and `docs/api-dx.md` itself, where low-level
names are discussed as subject matter rather than recommended style.

## Consumer Migration Evidence

This section records application migrations that exercise the preferred API in
real codebases. The goal is evidence, not post-hoc justification: each
migration should either strengthen the proposed surface or expose places where
the surface is still awkward.

### Camelpie

Repository: `/home/ribelo/projects/ribelo/camelpie`

Camelpie was migrated from visible raw `Eta.Effect.bind` usage to the preferred
surface across production code and tests. The final scan found no explicit
`Eta.Effect.bind`, pipeline-to-`bind`, or `bind_error (fun _ -> Effect.unit)` shapes
in the Camelpie repository.

What the migration proved:

- `Eta.Syntax.(let*)` and `let+` are enough for normal dependent sequencing and
  projection in CLI glue, daemon RPCs, STT flows, stream sessions, and tests.
- Synchronous leaves that already compute expected failures as `result` should
  use `Effect.sync_result f`. This keeps the defect boundary
  and typed-error lifting boundary visible without exposing `bind`.
- `Effect.with_resource` is the right first-contact lifecycle spelling for
  body-bounded acquisition/release. It made Pulse clients, record streams, and
  keyboard monitors read as scoped resource use rather than exposed primitive
  `acquire_release |> bind`.
- `Effect.ignore_errors` is valuable for best-effort effects such as
  cleanup, cancellation, and notifications, where the success value is
  unused. It is clearer than repeating
  `bind_error (fun _ -> Effect.unit)`.
- `Effect.to_result` is useful when a background workflow must publish either
  success or typed failure as data, as in the Codex realtime stream handoff.
- Queue close effect helpers are useful when close belongs inside an Eta
  workflow. They avoid ad hoc `Effect.sync (fun () -> Queue.close queue)` at
  stream finish/cancel boundaries.

The migration also found semantic bugs, not just cosmetic noise:

- Pulse connection failures were raised with `failwith`, which surfaced as
  unchecked defects instead of typed `Pulse_error` values. Rewriting connection
  acquisition to return `result` under `Effect.sync` and then lift it with
  `Effect.flatten_result` preserved the expected typed channel.
- Graphical session detection for text injection used `failwith` when no
  display was detected. Rewriting it as an Eta effect preserved the typed
  `Injection_error` channel.

Additional package-boundary evidence:

- Root `eta` should remain runtime-agnostic. Eio applications should depend on
  `eta_eio` for `Eta_eio.Runtime.create/run`.
- Eio HTTP/WebSocket construction belongs in `eta_http_eio`; protocol types,
  requests, responses, and errors stay in `eta_http`.
- Consumer repositories that path-pin a live Eta checkout need to avoid copying
  local build/test artifacts. Camelpie solved this with a filtered
  `.opam-eta-src/` snapshot that excludes generated state while preserving the
  package source needed by OPAM.

Not yet strengthened by Camelpie:

- Pure both-channel `fold` stayed less central than expected in Camelpie.
  Camelpie mostly needed effectful `bind_error`, best-effort `ignore_errors`, or
  `to_result` materialization. Keep `fold` as the pure both-channel helper, but
  do not treat it as core consumer evidence until another migration uses it
  naturally.

Verification:

```sh
cd /home/ribelo/projects/ribelo/camelpie
nix develop .#oxcaml -c dune build @install
nix develop .#oxcaml -c dune runtest --force
rg -n "Eta\\.Effect\\.bind|\\|>\\s*Eta\\.Effect\\.bind|Eta\\.Effect\\.bind_error \\(fun _ -> Eta\\.Effect\\.unit\\)" .
git diff --check
```

### Exergy

Repository: `/home/ribelo/projects/exergy`

Exergy was migrated across production code and tests to the preferred Eta
surface. The final audit, excluding generated/build/runtime data directories,
found no `Eta.Effect.bind`, pipeline-to-`bind`, old `Eta.Runtime.run`, or short
`Eta_blocking.result` / `result_timeout` spelling.

What the migration proved:

- `Eta.Syntax.(let*)` and `let+` scale to large real workflows: provider HTTP
  clients, SQLite ingest pipelines, Degiro/Yahoo/Citrini/Polymarket sync
  orchestration, retries, telemetry, and bounded concurrent quote fetching.
- `Eta_blocking.run_result` is the right public spelling for blocking leaves
  that already return typed `result`s. Exergy had many local storage helpers
  where manual `Ok`/`Error` unwrapping disappeared once result-returning
  blocking helpers were used directly.
- Synchronous parser boundaries that may raise while decoding JSON should keep
  exceptions as defects with `Effect.sync`, then lift expected parse failures
  with `Effect.sync_result`.
- `Effect.from_result` is the right spelling for already-computed parse,
  validation, and storage results inside a workflow. It replaced repeated
  `match result with Ok -> pure | Error -> fail` branches without hiding the
  typed error channel.
- `Effect.from_option` is the same boundary for already-computed optional
  lookup/extraction results where `None` is a typed failure. `Effect.sync_option
  ~if_none` is the thunk counterpart for synchronous option leaves.
- `Effect.with_result_attrs` is not just an observability nicety. It removed
  binds whose only purpose was attaching dynamic row-count/result attributes
  while preserving the success value.
- `Effect.tap` remains important in instrumentation-heavy code. Many workflows
  still intentionally use `tap` after a clean `let*` block to keep logging at
  the same semantic boundary.
- `Eta_eio.Runtime.run` should be the visible Eio runtime execution API in
  Eio consumers and tests. Exergy no longer uses root `Eta.Runtime.run`
  directly.
- The filtered `.opam-eta-src/` path-pin approach from Camelpie also fits
  Exergy. It avoids pinning stale Eta commits and avoids copying generated
  checkout artifacts into OPAM.

DX pressure found by Exergy:

- Large modules often mix pure `Result` syntax and Eta syntax. Local
  `let open Eta.Syntax in` blocks are the safest current style, but they are
  visually repetitive. This does not yet prove a new API is needed; it does
  justify documenting local-open style explicitly.
- Provider clients naturally repeat a local `decode_effect` helper:
  `let* json = effect in decode_result parse json`. This is application/domain
  specific enough to keep local for now; the reusable Eta primitive is still
  `Effect.from_result`.
- Telemetry-heavy storage helpers benefited from local helper APIs such as
  `observed_blocking` rather than more Eta primitives. Eta should keep the
  generic building blocks small; applications can name domain-specific
  observation policy.
- `Effect.fold` again did not become central. Exergy mostly needed effectful
  `bind_error`, `from_result`, `to_result`-as-data patterns, and explicit `tap`
  observers.

Verification:

```sh
nix develop -c dune build @install
nix develop -c dune runtest --force
nix develop -c exergy-oxcaml-check
rg -n "Eta\\.Effect\\.bind|\\|>\\s*Eta\\.Effect\\.bind|Eta\\.Effect\\.bind_error \\(fun _ -> Eta\\.Effect\\.unit\\)|Eta\\.Runtime\\.(create|run)|Eta_blocking\\.result\\b|Eta_blocking\\.result_timeout\\b" \
  -g '!_build/**' -g '!.opam-oxcaml/**' -g '!var/**' -g '!.motel-data/**' -g '!*.md'
git diff --check
```

## Verification

```sh
dune runtest test/api_dx --force
nix develop -c dune build @examples
nix develop -c dune exec examples/fold_recovery.exe
nix develop -c dune exec examples/validation_boundary.exe
nix develop -c dune exec examples/sync_defect_boundary.exe
nix develop -c dune exec examples/retry_schedule.exe
nix develop -c dune exec examples/repeat_heartbeat.exe
nix develop -c dune exec examples/service_composition.exe
nix develop -c dune exec examples/source_locations.exe
nix develop -c dune exec examples/tap_success.exe
nix develop -c dune exec examples/map_projection.exe
nix develop -c dune exec examples/all_health_checks.exe
nix develop -c dune exec examples/bounded_channel.exe
nix develop -c dune exec examples/channel_probe.exe
nix develop -c dune exec examples/blueprint_names.exe
nix develop -c dune exec examples/unbounded_queue.exe
nix develop -c dune exec examples/queue_probe.exe
nix develop -c dune exec examples/mutable_ref_state.exe
nix develop -c dune exec examples/deterministic_random.exe
nix develop -c dune exec examples/duration_budget.exe
nix develop -c dune exec examples/timeout_policy.exe
nix develop -c dune exec examples/uninterruptible_commit.exe
nix develop -c dune exec examples/error_rendering.exe
nix develop -c dune exec examples/log_level_policy.exe
nix develop -c dune exec examples/trace_sampling.exe
nix develop -c dune exec examples/trace_context_boundary.exe
nix develop -c dune exec examples/span_linking.exe
nix develop -c dune exec examples/exit_cause_boundary.exe
nix develop -c dune exec examples/finally_cleanup.exe
nix develop -c dune exec examples/runtime_boundary.exe
nix develop -c dune exec examples/manual_resource_refresh.exe
nix develop -c dune exec examples/observability_controls.exe
nix develop -c dune exec examples/observability_sinks.exe
nix develop -c dune exec examples/metric_batching.exe
nix develop -c dune exec examples/cached_resource.exe
nix develop -c dune exec examples/admission_control.exe
nix develop -c dune exec examples/semaphore_permits.exe
nix develop -c dune exec examples/connection_pool.exe
nix develop -c dune exec examples/pubsub_subscription.exe
nix develop -c dune exec examples/pubsub_poll.exe
nix develop -c dune exec examples/supervisor_scope.exe
nix develop -c dune exec examples/daemon_drain.exe
nix develop -c dune runtest test/blocking_eio --force
nix develop -c dune runtest examples --force
```
