# Effect surface audit

This audit is derived from `lib/eta/effect.mli` as of the current API-DX pass.
The interface exposes 73 `val` entries. A later reference pass against local ZIO
and Effect-smol sources proved that the previous `sync_result` and `tap_sync`
helpers were dominated aliases, not primitives. They were removed from the
public surface. The OCaml pipe-first replacement is `flatten_result`, which
keeps the `sync` boundary visible without exposing `bind`. The remaining
evidence supports a smaller recommended user style and a clearer split between
preferred, semantic, and low-level surfaces.

## Preferred user surface

These are the names a new application should see first. They are either used in
the promoted examples or directly support the same style.

| Group | Values | Evidence |
| --- | --- | --- |
| Constructors and typed leaves | `pure`, `fail`, `unit`, `from_result`, `flatten_result`, `sync` | Examples use `pure`, `fail`, `from_result`, `flatten_result`, and `sync`; validation-boundary proves `from_result` for pure validation; sync-defect proves `sync` for defect-capturing leaves; synchronous leaves that return `result` now compose `sync` with `flatten_result` explicitly. |
| Runtime scheduling | `yield` | The cooperative-yield bucket proves blueprint-level scheduling yield should use the runtime contract instead of hard-coding `Eio.Fiber.yield` in user workflow code. |
| Syntax-backed sequencing | `map`, `tap` | Public primitives remain, but user docs prefer `Eta.Syntax.(let+)` / `let*` for ordinary sequencing; the map-projection example uses `let+` for pure projection, and the tap-success/sync-observer examples use `tap` for success-side observation while preserving the original value. Direct `bind` is not needed in examples. |
| Typed recovery and materialization | `catch`, `recover`, `ignore_errors`, `result`, `map_error`, `tap_error` | API-DX evidence keeps `catch` for effectful recovery, `recover` for pure recovery, `ignore_errors` for best-effort unit effects, and `result` for keeping success/failure as data inside the workflow; error mapping/observation is a distinct typed-error capability. |
| Time and retry | `retry`, `delay`, `timeout`, `timeout_as`, `repeat` | Resource/CLI/test examples use `retry`, `delay`, and `timeout_as`; the repeat-heartbeat example uses `repeat`; `timeout` is the same semantic family. |
| Interruption control | `uninterruptible` | The critical-commit example proves cancellation can be deferred around a small branch without changing the typed error channel. |
| Body-bounded lifecycle | `with_resource`, `finally` | Resource example uses `with_resource`; `finally` remains the one-shot cleanup shape. |
| Wider lifecycle and background work | `scoped`, `acquire_release`, `with_background`, `daemon` | Docs distinguish body-bounded resources from wider scope/runtime-owned lifetimes. |
| Concurrency | `race`, `par`, `all`, `all_settled`, `for_each_par`, `for_each_par_bounded` | Batch, all-collect, and race examples prove bounded fan-out, fail-fast list collection, settled outcomes, and first-success racing; syntax only covers two-way foreground concurrency. |
| Observability | `named`, `named_kind`, `with_error_renderer`, `annotate`, `annotate_all`, `annotate_all_lazy`, `is_tracing_enabled`, `suppress_observability`, `event`, `with_result_attrs`, `link_span`, `with_external_parent`, `with_context`, `current_span`, `current_context`, `log`, `metric_update`, `metric`, `metric_updates`, `metric_updates_lazy`, `here_attr`, `fn` | Root Eta owns interpretation and observability hooks; docs and tests exercise this as a first-class capability. |

## Diagnostic/preflight surface

These are not primary workflow combinators, but the promoted examples use them
directly for blueprint inspection.

| Group | Values | Evidence |
| --- | --- | --- |
| Static name inspection | `name`, `collect_names` | The blueprint-names example inspects statically present names before runtime interpretation and proves the documented dynamic-continuation boundary. |

## Low-level or advanced surface

These should not be first-contact user style. They remain justified as
implementation, combinator, or extension hooks unless later evidence proves
otherwise.

| Group | Values | Current classification |
| --- | --- | --- |
| Primitive sequencing | `bind`, `(>>=)` | Primitive under `Eta.Syntax`; guarded examples and selected docs do not use them directly. |
| Batch unit sequencing | `seq`, `concat` | Convenience primitives for unit effects; no evidence to remove, but not part of preferred examples. |
| Direct bracket spelling | `acquire_use_release` | Doc-dominated by `with_resource`; not proven harmful enough to remove. |
| Supervisor implementation bridge | `supervisor_scoped`, `supervisor_pure`, `supervisor_lift`, `supervisor_fail`, `supervisor_bind`, `supervisor_start`, `supervisor_await`, `supervisor_cancel`, `supervisor_failures`, `supervisor_check`, `supervisor_yield` | Low-level abstract builders used by `Supervisor`; user code should prefer `Supervisor.scoped` and `Supervisor.Scope`. |
| Runtime extension hook | `Expert.*` | Needed by runtime/optional packages while keeping the `Effect.t` representation private. |

## Current conclusion

The minimum user-facing Eta style is smaller than the raw `Effect` signature:

- build leaves with `pure`, `fail`, `from_result`, `flatten_result`, and
  `sync`;
- use `Effect.sync` when raised exceptions should remain unchecked defects;
- when a synchronous leaf returns expected typed failures as `result`, use
  `Effect.sync f |> Effect.flatten_result`;
- use `Effect.yield` when a blueprint should cooperatively yield to the active
  runtime backend;
- use `Effect.from_result` for already-computed validation/parsing results
  instead of wrapping them in a synchronous leaf;
- sequence with `Eta.Syntax` rather than direct `bind`;
- use `Eta.Syntax.(let+)` for pure success-value projection instead of `bind`
  plus `pure`;
- use `Effect.tap` for success-side observers that should preserve the original
  value; wrap plain synchronous observers with `Effect.sync`;
- use `Effect.catch` for effectful typed failure recovery and
  `Effect.recover` for pure typed failure recovery inside an Eta blueprint
  instead of moving expected failures into successful `result` values;
- use `Effect.ignore_errors` only for best-effort unit effects where typed
  failures should be suppressed but defects and cancellation should remain
  visible;
- use `Effect.result` when both success and typed failure should become
  ordinary data for the next workflow step while defects and finalizers remain
  Eta causes;
- use `Effect.all` for homogeneous dynamic lists of independent effects where
  fail-fast collection is desired;
- use named lifecycle helpers such as `with_resource` and `with_background`;
- use `Effect.repeat` for scheduled unit-work recurrence instead of manually
  driving `Schedule.start` / `Schedule.next`;
- use `Effect.timeout_as` for domain-typed timeout policies instead of
  hand-written `race` plus delayed failure;
- use `Effect.uninterruptible` only around small critical effects that must
  finish once started;
- use `Effect.finally` for one-shot cleanup around an existing effect instead
  of hand-written `catch` cleanup;
- use `Effect.fn __POS__ __FUNCTION__` for function-name spans with source
  locations rather than hand-formatted `loc` attributes;
- use `Effect.with_error_renderer` when typed failures need meaningful
  observability diagnostics without changing the typed error channel;
- use optional-package boundary helpers such as `Eta_blocking.run_result` when a
  package owns a stronger leaf protocol than core `Effect.sync`;
- keep `Supervisor.scoped { run = ... }` visible when code needs child handles;
  the rank-2 body record is what prevents handles from escaping their nursery,
  and the supervisor metric gate proves this shape can stay bind-free for
  users through `Supervisor.Scope.(let*)`;
- keep explicit runtime ownership at the application boundary;
- keep observability, metric batching, and structured concurrency as
  first-class Eta strengths.

Nearby core primitives are evaluated through the same lens even when they are
not `Effect.mli` values. The schedule bucket keeps `Schedule.recurs`,
`Schedule.exponential`, `Schedule.jittered`, `Schedule.start`, and
`Schedule.next` visible because they encode pure retry/repeat policy
description, bounded recurrence, deterministic runtime jitter, and interpreter
driver state that recursive retry loops and ad hoc sleeps would otherwise force
users to reimplement. The validation-boundary bucket keeps `Effect.from_result`
visible because pure validation/parsing results that are already computed
should be lifted directly, not wrapped in a synchronous leaf. When the leaf
itself computes a result under Eta's defect and cancellation boundary, compose
`Effect.sync` with `Effect.flatten_result` explicitly. The sync-defect bucket keeps
`Effect.sync` visible
because unexpected exceptions from synchronous leaves should surface as
`Cause.Die`, not be converted to typed domain failures with ad hoc `try` /
`Error` wrappers. The cooperative-yield bucket keeps `Effect.yield` visible
because workflow scheduling points should use Eta's runtime contract, not a
backend-specific `Effect.sync Eio.Fiber.yield` leaf. The map-projection bucket keeps `Eta.Syntax.(let+)`
visible because pure success-value projection should not require spelling
`bind` plus `pure`. Use `let*` when the continuation returns another effect;
use `let+` when it is pure. The tap-success bucket keeps `Effect.tap` visible
because success-side observation should not require spelling the primitive
`bind` plus `map` pattern every time an observer preserves the original value.
The sync-observer bucket proves that plain synchronous observers are still
expressible with `Effect.tap (fun value -> Effect.sync (fun () -> observe
value))`. Use `let*` when later work depends on the observer's result; use
`tap` when the observer is part of the Eta workflow.
The catch-recovery bucket keeps `Effect.catch` visible because expected domain
failures should remain in Eta's typed error channel, not be encoded as
successful `result` values just to branch with `bind`. The same example also
proves defects stay outside typed recovery. The pure-recovery bucket keeps
`Effect.recover` visible because recovering to a plain success value should not
require wrapping the value with `Effect.pure`. Use `catch` when recovery itself
is effectful; use `recover` when it is pure.
The best-effort bucket keeps `Effect.ignore_errors` visible because unit
cleanup/refresh/notification effects should not require spelling
`Effect.catch (fun _ -> Effect.unit)` every time typed failure suppression is
intentional. It does not catch defects, interruption, or finalizer diagnostics.
The typed-failure-result bucket keeps `Effect.result` visible because
materializing success/failure as an OCaml `result` inside a workflow should not
require spelling `Effect.map (fun value -> Ok value) |> Effect.recover ...`.
It does not replace `catch` / `recover`; it is only for cases where both
outcomes are ordinary data for the next step.
The all-collect bucket keeps `Effect.all` visible because a dynamic homogeneous
list of independent effects should not require a recursive `bind` / `map` loop.
Use syntax `and*` for fixed arity with potentially different result types,
`for_each_par_bounded` for mapped input workloads with a concurrency limit, and
`all_settled` when every child outcome is the value being collected.
The repeat-heartbeat bucket keeps `Effect.repeat` visible
because application code should describe scheduled unit work while Eta drives
the schedule driver, sleeps, cancellation, and iteration failure behavior.
Manual recursion over `Schedule.start` / `Schedule.next` is still useful inside
interpreters, but is not the preferred application shape. The duration bucket keeps `Duration.ms`,
`Duration.seconds`, `Duration.add`, `Duration.subtract`, `Duration.times`,
`Duration.scale`, `Duration.clamp`, `Duration.between`, `Duration.to_ms`, and
`Duration.pp` visible because they keep time budgets on a typed, non-negative,
millisecond-precision value shared by schedules, delays, timeouts, test clocks,
and runtime sleep bridges. Raw integers or floats can match line count but
force callers to own unit conversion and clamping. The timeout-policy bucket
keeps `Effect.timeout_as` and `Effect.timeout` visible because a timeout is not
just a delayed branch in a race: the runtime must cancel the losing body, wait
for body cleanup, preserve body/finalizer failures that surface during
cancellation, and map timeout selection into the caller's typed error row.
Manual `race` plus `delay` can match the simple happy line count but forces
every caller to own those lifecycle semantics. Raw `` `Timeout`` remains a
reasonable row member when `Effect.timeout` is the desired shortcut. The
uninterruptible-commit bucket keeps `Effect.uninterruptible` visible because a
small critical effect sometimes needs parent cancellation to wait until it has
finished. The helper marks that boundary explicitly without catching defects,
turning interruption into a typed failure, or asking every caller to re-create
backend cancellation protection. It is not a blanket for long-running work.
The log-level bucket keeps
`Log_level.of_string`, `Log_level.is_enabled`, `Log_level.to_string`,
`Log_level.to_otel_severity`, `Log_level.of_otel_severity`, and `Log_level.pp`
visible because they centralize case-insensitive parsing, `All` / `Off`
threshold semantics, comparison, rendering, and OTLP severity-number mapping.
Raw strings, ranks, and severity numbers remain external formats, not the
policy representation. The log-level-boundary bucket narrows the boundary
point: use `to_string`, `to_otel_severity`, `of_otel_severity`, and `pp`
instead of maintaining raw string and integer ladders in exporters. The random bucket keeps
`Capabilities.random_of_seed`,
`Capabilities.random_set_seed`, and `Random.*` helpers visible because they
encode deterministic, portable random draws over the same token used by runtime
schedules; naked `Capabilities.random_float` math or `Stdlib.Random` would
break that replay story or force callers to reimplement range, shuffle,
weighted-choice, and sample helpers.
The sampler bucket keeps `Sampler.always_on`, `Sampler.always_off`,
`Sampler.ratio`, `Sampler.parent_based`, and `Sampler.sample` visible because
they name the runtime trace-sampling policy, clamp ratio bounds, and preserve
parent-based sampling decisions without making applications own ad hoc
trace-id hashing. The trace-context bucket keeps `Trace_context.extract`,
`Trace_context.inject`, `Trace_context.make`, `Effect.with_context`, and
`Effect.current_context` visible because they encode W3C propagation
validation, sampled flags, tracestate, baggage, and runtime external-parent
semantics that manual `traceparent` slicing or `Effect.with_external_parent`
would lose. The trace-context-injection bucket makes the outbound side explicit:
read the runtime context with `Effect.current_context` and serialize it with
`Trace_context.inject` instead of hand-formatting W3C headers. The span-link bucket keeps `Effect.current_span`,
`Effect.link_span`, and `Effect.named_kind` visible because causal relationships
between spans should be tracer-native links and span kinds, not string
attributes that exporters cannot interpret structurally. The source-location
bucket keeps `Effect.fn` visible as the preferred application helper for
function-name spans and compiler source positions, and keeps `Effect.here_attr`
visible as the lower-level wrapper primitive for passing `__POS__` through
unchanged without inventing a source location. The error-rendering bucket keeps
`Effect.with_error_renderer` and `?error_renderer` visible because typed failure
values should stay typed while span statuses, exception events, and finalizer
diagnostics still receive useful strings. The blueprint-names
bucket keeps `Effect.name` and `Effect.collect_names` visible as
diagnostic/preflight helpers because they inspect the existing effect
description before runtime interpretation without requiring a parallel manual
registry. They are intentionally not a complete runtime inventory because
forcing continuation-producing nodes would change what inspection means. The
exit/cause bucket keeps `Exit.to_result`, `Exit.pp`,
`Cause.pp`, `Cause.Finalizer`, and `Cause.Suppressed` visible because the
runtime exit channel can represent defects, interruptions, finalizer failures,
suppressed cleanup failures, and composed causes that ordinary OCaml `result`
cannot faithfully encode. The runtime-boundary bucket keeps `Runtime.run` as
the preferred execution boundary because it preserves that full `Exit` value;
`Runtime.run_exn` remains visible only for tests and top-level programs that
intentionally collapse non-success exits to raised exceptions. The
finally-cleanup bucket keeps `Effect.finally` visible because one-shot cleanup
must run on success, typed failure, defect, and cancellation, and cleanup
failures must stay in Eta's finalizer/suppressed-cause model. The
service-composition bucket keeps Eta's application service story deliberately
small: pass ordinary OCaml values, records, modules, or closures, and use Eta
only for effectful construction and cleanup. `Runtime_contract.create_service_key`,
`Runtime_contract.Service`, and `Effect.Expert.runtime_service` remain advanced
optional-package hooks for backend-attached services, not a general Layer or
environment channel. The cached-resource bucket keeps `Resource.auto`,
`Resource.get`, and `Resource.failures` visible because they encode a
runtime-owned refresh loop, last-good-value preservation, and refresh-failure
diagnostics that `with_background` plus a mutable ref would otherwise force
users to reimplement. The resource-failures bucket narrows the diagnostic
point: `~on_error` remains an immediate side-effect hook, while
`Resource.failures` is the Eta-owned cause ledger and avoids a caller-maintained
side-channel ref. The manual-resource bucket keeps `Resource.manual`,
`Resource.refresh`, and `Resource.get` visible because caller-driven refresh has
a different lifecycle: refresh failures return through the caller's typed
channel and last-good-value publication remains resource-owned. The pool bucket keeps `Pool.create`,
`Pool.with_resource`, `Pool.shutdown`, and `Pool.stats` visible because they
encode bounded checkout, idle reuse, shutdown/close accounting, cancellation
cleanup, health checks, and optional eviction that a semaphore plus mutable
idle slot would otherwise force users to reimplement. The pubsub bucket keeps
`Pubsub.subscribe`, `Pubsub.publish`, `Pubsub.recv`, and close/error propagation
visible because they encode scoped subscription lifetime and retained-message
cleanup that escaping subscriptions or manual fan-out would otherwise force
users to reimplement. The pubsub-poll bucket keeps `Pubsub.try_recv` visible
because non-blocking subscription reads need the subscription cursor and typed
close result; hub-level `Pubsub.stats` is not a substitute for per-subscriber
state. The bounded-channel bucket keeps `Channel.create`,
`Channel.send`, `Channel.recv`, and close/error propagation visible because
they encode bounded same-domain handoff, sender backpressure, waiter cleanup,
FIFO draining, and close fences that `Queue`, `Semaphore`, or naked refs would
otherwise force users to reimplement. The channel-probe bucket keeps
`Channel.try_send` and `Channel.try_recv` visible because non-blocking probes
need the channel's own state transition and typed close reason; a
caller-maintained `Channel.stats` capacity check is only a racy approximation.
The handoff-close bucket keeps `Channel.close_effect`,
`Channel.close_with_error_effect`, `Queue.close_effect`,
`Queue.close_with_error_effect`, `Pubsub.close_effect`, and
`Pubsub.close_with_error_effect` visible because close is a workflow action
when it is sequenced after sends or publishes; raw immediate close functions
remain available for host callbacks and low-level internals.
The handoff-snapshot bucket does not justify `stats_effect` wrappers:
`Channel.stats`, `Queue.stats`, `Pubsub.stats`, `Semaphore.available`, and
`Semaphore.waiting` are plain snapshots. Read them directly inside the
continuation and lift the final combined value once when an effect is still
needed.
The unbounded-queue bucket keeps
`Queue.create`, `Queue.send`, `Queue.recv`, `Queue.stats`, and close/error
propagation visible because they encode unbounded same-domain handoff,
receiver-waiter cleanup, buffered drain after close, and close fences that
`Channel`, `Pubsub`, `Semaphore`, or naked refs would otherwise change or force
users to reimplement. The queue-probe bucket keeps `Queue.try_send` and
`Queue.try_recv` visible because non-blocking queue probes need the queue's own
state transition and typed close reason; a caller-maintained `Queue.stats`
check is only a racy approximation. The mutable-ref bucket keeps `Mutable_ref.make`,
`Mutable_ref.update`, `Mutable_ref.update_and_get`, and
`Mutable_ref.get_and_set` visible because they document application-owned shared
state and keep CAS retry loops out of synchronous leaves without making Eta own
that state. The semaphore-permit bucket keeps `Semaphore.with_permits` visible
because lexical permit ownership needs cleanup on success, typed failure,
defect, and cancellation without a caller-maintained release path. The
admission-control bucket keeps `Semaphore.with_permits_or_abort` visible because
abortable admission needs the same cleanup invariant plus a typed abort result.
Raw `Semaphore.try_acquire`, `Semaphore.acquire`, and `Semaphore.release`
remain low-level operations for custom protocols and internals, but they are
not the preferred application shape.
The metric-batching bucket keeps `Effect.metric_update`, `Effect.metric`,
`Effect.metric_updates`, and `Effect.metric_updates_lazy` visible because they
let a blueprint decide at interpretation time whether metric snapshot/allocation
work is needed. A caller can emit one metric directly, batch related metrics
under one timestamp, or skip building a whole batch when no meter is installed
without passing `Runtime.metrics_enabled` through application code.
The observability-controls bucket keeps `Effect.is_tracing_enabled`,
`Effect.annotate_all_lazy`, and `Effect.suppress_observability` visible because
runtime observability state should remain interpreter-owned. External booleans
can match neither dynamic runtime selection nor observer/exporter recursion
suppression without leaking runtime state into application code.
The observability-sinks bucket keeps `Tracer.in_memory`, `Tracer.as_capability`,
`Tracer.dump`, `Tracer.retain_recent`, `Logger.in_memory`,
`Logger.as_capability`, `Logger.dump`, `Meter.in_memory`, `Meter.as_capability`,
and `Meter.dump` visible because tests and diagnostic adapters need synchronized
runtime-compatible sinks without reimplementing the capability object protocols.
The daemon-drain bucket keeps `Effect.daemon` and `Runtime.drain` visible
because runtime-owned finite infrastructure work has a different lifecycle from
body-owned `Effect.with_background`: it is not cancelled when the caller's body
returns, and tests or process shutdown need an explicit drain point.

No deletion is justified yet. The next deletion-oriented pass would need to
prove that a low-level public value is both unused outside implementation
boundaries and actively worsens the API after docs and examples have been
corrected.
