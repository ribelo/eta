# Eta API DX bucket 1 results

## Supersession note: 2026-06-17

The earlier additive recommendation for `Effect.sync_result` and
`Effect.tap_sync` was reversed after checking the local ZIO and Effect-smol
reference sources. Both ecosystems expose effectful `tap`, and neither exposes
a public `sync_result` / `tap_sync`-style helper. Eta now removes those two
derived helpers from the public surface.

Current rule:

- Use `Effect.sync` for the synchronous defect boundary.
- Use `Effect.from_result` to lift an already-computed OCaml `result` into the
  typed error channel.
- Use `Effect.flatten_result` to flatten an effect that succeeds with `result`.
- If a synchronous leaf returns `result`, spell both boundaries explicitly:
  `Effect.sync f |> Effect.flatten_result`.
- Use `Effect.tap` for success-side observation; wrap plain synchronous
  observers with `Effect.sync`.

## Status

Accepted small additive API changes:

- `Effect.flatten_result`
- `Effect.recover`
- `Effect.ignore_errors`
- `Effect.result`
- `Effect.yield`
- `Effect.with_resource`
- `Eta_http.Server.Handler.of_effect`
- `Eta_http.Server.Handler.of_sync`
- `Eta_http.Server.Handler.of_result`
- `Eta_blocking.run_result`
- `Eta_blocking.run_result_timeout`
- `Effect.metric`
- `Effect.metric_updates`
- `Effect.metric_updates_lazy`
- `Eta.Channel.close_effect`
- `Eta.Channel.close_with_error_effect`
- `Eta.Queue.close_effect`
- `Eta.Queue.close_with_error_effect`
- `Eta.Pubsub.close_effect`
- `Eta.Pubsub.close_with_error_effect`

Deleted after follow-up evidence:

- `Effect.sync_result`
- `Effect.tap_sync`

## Evidence

The live compile gate is `test/api_dx/api_dx_examples.ml`. It covers sixty-four
example areas: resource workflow, runtime-owned cached resources, scoped
resource handles, ordinary service composition, typed failure recovery,
pure typed failure recovery, best-effort typed failure suppression,
typed failure materialization as `result`,
backend-neutral cooperative yielding, success-value projection, pure validation
lifting, synchronous defect capture,
retrying external call, stream transform,
success-side observation, synchronous success-side observation, scheduled unit recurrence, fail-fast list
collection, bounded batch concurrency, bounded channels, non-blocking channel
probes, effectful handoff close, direct handoff snapshots, unbounded queues, shared mutable state, composed retry schedules, typed
duration budgets, typed timeout policies, cancellation-protected critical
effects, deterministic scalar and collection random helpers, log-level policies
and severity boundaries, racing mirrors, typed-error boundaries,
runtime exit/cause boundaries, runtime execution boundaries, lexical semaphore
permits, abortable admission control, runtime-local pools, scoped pubsub subscriptions, non-blocking pubsub
polls, non-blocking queue probes, trace sampling, trace context propagation, trace context injection, static blueprint name inspection,
source-location function spans, typed-error rendering, one-shot cleanup, HTTP handler, test program,
small CLI/business workflow, blocking typed leaf, observability, observability controls,
observability sinks, lazy metric batching, background lifecycle, runtime-owned
daemon draining, supervised nurseries, runtime-owned resource failure
diagnostics, caller-driven manual resource refresh, and span linking.

Command:

```sh
dune runtest test/api_dx --force
nix develop -c dune runtest --force
```

Latest output:

```text
resource,current,lines=5,effect_bind=2,let_star=0,let_at=0,from_result=1
resource,proposed,lines=3,effect_bind=0,let_star=0,let_at=1,from_result=0
cached_resource,current,lines=13,effect_bind=3,let_star=0,let_at=0,from_result=0
cached_resource,proposed,lines=3,effect_bind=0,let_star=1,let_at=0,from_result=0
resource_failures,current,lines=6,effect_bind=0,let_star=2,let_at=0,from_result=0
resource_failures,proposed,lines=4,effect_bind=0,let_star=2,let_at=0,from_result=0
manual_resource,current,lines=12,effect_bind=4,let_star=0,let_at=0,from_result=0
manual_resource,proposed,lines=4,effect_bind=0,let_star=2,let_at=0,from_result=0
scoped_resource,current,lines=4,effect_bind=1,let_star=0,let_at=0,from_result=0
scoped_resource,proposed,lines=6,effect_bind=0,let_star=2,let_at=0,from_result=0
service,current,lines=6,effect_bind=0,let_star=0,let_at=0,from_result=0
service,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
catch_recovery,current,lines=4,effect_bind=1,let_star=0,let_at=0,from_result=0
catch_recovery,proposed,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
pure_recovery,current,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
pure_recovery,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
best_effort,current,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
best_effort,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
typed_failure_result,current,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
typed_failure_result,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
validation_boundary,current,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
validation_boundary,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=1
sync_defect,current,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
sync_defect,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
source_location,current,lines=4,effect_bind=0,let_star=0,let_at=0,from_result=0
source_location,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
error_rendering,current,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
error_rendering,proposed,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
tap_success,current,lines=3,effect_bind=1,let_star=0,let_at=0,from_result=0
tap_success,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
tap_sync_observer,current,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
tap_sync_observer,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
success_map,current,lines=3,effect_bind=1,let_star=0,let_at=0,from_result=0
success_map,proposed,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
finally_cleanup,current,lines=5,effect_bind=2,let_star=0,let_at=0,from_result=0
finally_cleanup,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
timeout_policy,current,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
timeout_policy,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
uninterruptible_commit,current,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
uninterruptible_commit,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
cooperative_yield,current,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
cooperative_yield,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
retry,current,lines=3,effect_bind=1,let_star=0,let_at=0,from_result=1
retry,proposed,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
schedule_retry,current,lines=9,effect_bind=1,let_star=0,let_at=0,from_result=1
schedule_retry,proposed,lines=6,effect_bind=0,let_star=0,let_at=0,from_result=0
repeat_heartbeat,current,lines=8,effect_bind=1,let_star=0,let_at=0,from_result=0
repeat_heartbeat,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
stream,current,lines=4,effect_bind=1,let_star=0,let_at=0,from_result=1
stream,proposed,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
batch,current,lines=6,effect_bind=1,let_star=0,let_at=0,from_result=0
batch,proposed,lines=6,effect_bind=0,let_star=1,let_at=0,from_result=0
all_collect,current,lines=8,effect_bind=1,let_star=0,let_at=0,from_result=0
all_collect,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
blueprint_names,current,lines=4,effect_bind=0,let_star=0,let_at=0,from_result=0
blueprint_names,proposed,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
channel,current,lines=16,effect_bind=5,let_star=0,let_at=0,from_result=0
channel,proposed,lines=12,effect_bind=0,let_star=5,let_at=0,from_result=0
channel_probe,current,lines=19,effect_bind=0,let_star=1,let_at=0,from_result=0
channel_probe,proposed,lines=4,effect_bind=0,let_star=1,let_at=0,from_result=0
queue,current,lines=18,effect_bind=7,let_star=0,let_at=0,from_result=0
queue,proposed,lines=11,effect_bind=0,let_star=7,let_at=0,from_result=0
handoff_close,current,lines=4,effect_bind=0,let_star=2,let_at=0,from_result=0
handoff_close,proposed,lines=4,effect_bind=0,let_star=2,let_at=0,from_result=0
handoff_snapshot,current,lines=8,effect_bind=0,let_star=3,let_at=0,from_result=0
handoff_snapshot,proposed,lines=7,effect_bind=0,let_star=0,let_at=0,from_result=0
queue_probe,current,lines=19,effect_bind=0,let_star=1,let_at=0,from_result=0
queue_probe,proposed,lines=4,effect_bind=0,let_star=1,let_at=0,from_result=0
mutable_ref,current,lines=10,effect_bind=0,let_star=0,let_at=0,from_result=0
mutable_ref,proposed,lines=5,effect_bind=0,let_star=0,let_at=0,from_result=0
random,current,lines=7,effect_bind=0,let_star=0,let_at=0,from_result=0
random,proposed,lines=4,effect_bind=0,let_star=0,let_at=0,from_result=0
random_collections,current,lines=23,effect_bind=0,let_star=0,let_at=0,from_result=0
random_collections,proposed,lines=4,effect_bind=0,let_star=0,let_at=0,from_result=0
duration,current,lines=7,effect_bind=0,let_star=0,let_at=0,from_result=0
duration,proposed,lines=8,effect_bind=0,let_star=0,let_at=0,from_result=0
log_level,current,lines=9,effect_bind=0,let_star=0,let_at=0,from_result=0
log_level,proposed,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
log_level_boundary,current,lines=16,effect_bind=0,let_star=0,let_at=0,from_result=0
log_level_boundary,proposed,lines=5,effect_bind=0,let_star=0,let_at=0,from_result=0
sampler,current,lines=4,effect_bind=0,let_star=0,let_at=0,from_result=0
sampler,proposed,lines=4,effect_bind=0,let_star=0,let_at=0,from_result=0
trace_context,current,lines=6,effect_bind=0,let_star=0,let_at=0,from_result=0
trace_context,proposed,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
trace_context_injection,current,lines=13,effect_bind=0,let_star=0,let_at=0,from_result=0
trace_context_injection,proposed,lines=5,effect_bind=0,let_star=1,let_at=0,from_result=0
span_link,current,lines=5,effect_bind=0,let_star=0,let_at=0,from_result=0
span_link,proposed,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
exit_cause,current,lines=7,effect_bind=0,let_star=0,let_at=0,from_result=0
exit_cause,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
runtime_boundary,current,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
runtime_boundary,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
race,current,lines=7,effect_bind=1,let_star=0,let_at=0,from_result=0
race,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
typed_error,current,lines=5,effect_bind=1,let_star=0,let_at=0,from_result=1
typed_error,proposed,lines=5,effect_bind=0,let_star=1,let_at=0,from_result=1
admission,current,lines=13,effect_bind=1,let_star=0,let_at=0,from_result=0
admission,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
semaphore_permit,current,lines=5,effect_bind=1,let_star=0,let_at=0,from_result=0
semaphore_permit,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
pool,current,lines=17,effect_bind=2,let_star=0,let_at=0,from_result=0
pool,proposed,lines=7,effect_bind=0,let_star=4,let_at=0,from_result=0
pubsub,current,lines=8,effect_bind=2,let_star=0,let_at=0,from_result=0
pubsub,proposed,lines=6,effect_bind=0,let_star=2,let_at=1,from_result=0
pubsub_poll,current,lines=6,effect_bind=0,let_star=0,let_at=0,from_result=0
pubsub_poll,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
http,current,lines=4,effect_bind=0,let_star=0,let_at=0,from_result=0
http,proposed,lines=5,effect_bind=0,let_star=0,let_at=0,from_result=0
test,current,lines=3,effect_bind=1,let_star=0,let_at=0,from_result=1
test,proposed,lines=4,effect_bind=0,let_star=2,let_at=0,from_result=1
cli,current,lines=4,effect_bind=1,let_star=0,let_at=0,from_result=1
cli,proposed,lines=4,effect_bind=0,let_star=2,let_at=0,from_result=1
blocking,current,lines=2,effect_bind=1,let_star=0,let_at=0,from_result=1
blocking,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
supervisor,current,lines=6,effect_bind=0,let_star=0,let_at=0,from_result=0
supervisor,proposed,lines=8,effect_bind=0,let_star=3,let_at=0,from_result=0
observability,current,lines=7,effect_bind=2,let_star=0,let_at=0,from_result=0
observability,proposed,lines=8,effect_bind=0,let_star=2,let_at=0,from_result=0
metric_batch,current,lines=9,effect_bind=0,let_star=4,let_at=0,from_result=0
metric_batch,proposed,lines=8,effect_bind=0,let_star=0,let_at=0,from_result=0
observability_controls,current,lines=5,effect_bind=1,let_star=0,let_at=0,from_result=0
observability_controls,proposed,lines=9,effect_bind=0,let_star=3,let_at=0,from_result=0
observability_sinks,current,lines=14,effect_bind=0,let_star=0,let_at=0,from_result=0
observability_sinks,proposed,lines=8,effect_bind=0,let_star=0,let_at=0,from_result=0
background,current,lines=5,effect_bind=1,let_star=0,let_at=0,from_result=0
background,proposed,lines=6,effect_bind=0,let_star=2,let_at=0,from_result=0
daemon_drain,current,lines=6,effect_bind=0,let_star=0,let_at=0,from_result=0
daemon_drain,proposed,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
```

The proposed shape removes explicit `Effect.bind` from all sixty-four areas.
`let*` remains in sequencing-heavy test and CLI examples, where it marks workflow
ordering, in cached-resource setup/get, in caller-driven manual resource
refresh, in scoped-resource setup/use, in the
typed-error boundary example, where it marks domain input validation before
loading, and in the observability example, where it marks ordered signal
emission, and in the observability-controls example, where it queries runtime
tracing state before running a suppressed observer subtree. It also sequences
the bounded batch result before inspecting settled outcomes. `and*` marks
independent concurrent foreground work in the background lifecycle and
scoped-resource examples. `let@` appears only in the body-bounded resource
example, where it marks callback lifetime.
`Supervisor.Scope.(let*)` remains inside the supervisor nursery example because
child handles are scoped values and cannot be sequenced with ordinary
`Eta.Syntax.(let*)`.
`Effect.sync_result` removes the repeated `Effect.sync |> Effect.bind
Effect.from_result` leaf pattern from resource, retry, and stream examples.
`Effect.tap_sync` removes raw `Effect.sync` wrapping around synchronous
success observers while keeping `Effect.tap` for effectful observers.
`Effect.recover` removes `Effect.catch (fun err -> Effect.pure (...))` when
typed failure recovery computes a plain success value, while keeping
`Effect.catch` for effectful recovery.
`Effect.ignore_errors` removes `Effect.catch (fun _ -> Effect.unit)` from
best-effort unit effects while preserving defects, interruption, and finalizer
diagnostics.
`Effect.result` removes the `Effect.map (fun value -> Ok value) |>
Effect.recover (fun err -> Error err)` pattern when a workflow wants to keep
both success and typed failure as ordinary data.
`Effect.yield` removes `Effect.sync Eio.Fiber.yield` from blueprint-level
scheduling points and delegates to the active runtime backend.
`Eta_blocking.run_result` removes the analogous `Eta_blocking.run |>
Effect.bind Effect.from_result` pattern from blocking leaves.
`Resource.auto` removes the manual cache/ref/background-refresh protocol from
runtime-owned cached-resource code.
`Resource.failures` removes caller-owned side-channel diagnostic refs for
scheduled refresh failures and keeps refresh failures in Eta's cause model.
`Random.shuffle`, `Random.weighted_choice`, and `Random.sample` remove
hand-written deterministic collection draw protocols over raw `random_float`.
`Log_level.to_string`, `to_otel_severity`, `of_otel_severity`, and `pp` remove
manual string rendering and OTLP severity ladders at log exporter boundaries.
`Effect.current_context` plus `Trace_context.inject` remove hand-written
outbound W3C propagation header construction.
`Channel.try_send` and `Channel.try_recv` remove caller-maintained capacity
checks around non-blocking bounded-channel probes and preserve typed close
results.
`Pubsub.try_recv` removes hub-level stats guesses around non-blocking scoped
subscription polls and preserves per-subscription empty/item/close results.
`Queue.try_send` and `Queue.try_recv` remove caller-maintained stats checks
around non-blocking unbounded-queue probes and preserve typed close results.
`Channel.close_effect` / `close_with_error_effect`, `Queue.close_effect` /
`close_with_error_effect`, and `Pubsub.close_effect` /
`close_with_error_effect` remove raw `Effect.sync` lifting when handoff close
is part of the workflow blueprint.
Direct `Channel.stats`, `Queue.stats`, `Pubsub.stats`, and semaphore counter
snapshots remove raw `Effect.sync` lifting for plain state inspection without
adding `stats_effect` wrappers.
`Semaphore.with_permits` removes manual acquire/release/finalizer plumbing for
lexical permit ownership.
`Semaphore.with_permits_or_abort` removes the manual acquire/abort/finalizer
protocol from admission-control code.
`Pool.create`/`Pool.with_resource`/`Pool.shutdown` remove the manual
semaphore/ref idle-cache protocol from runtime-local pool code.
`Pubsub.subscribe` with `let@` removes callback/bind-heavy subscription setup
from publish/subscribe workflows while preserving scoped subscription lifetime.
`Channel.send`/`Channel.recv` remain direct message operations, but the promoted
shape uses syntax-backed producer/consumer sequencing and proves backpressure
plus typed close propagation without explicit bind.
`Queue.send`/`Queue.recv` also remain direct message operations, but the
promoted shape uses syntax-backed FIFO drain sequencing and proves unbounded
buffering plus typed close propagation without explicit bind.
`Effect.metric_updates_lazy` removes repeated metric-emission sequencing from
hot observability paths and lets the runtime decide whether metric snapshot and
allocation work should happen at interpretation time.
`Effect.is_tracing_enabled`, `Effect.annotate_all_lazy`, and
`Effect.suppress_observability` keep observability state interpreter-owned:
application code does not need to pass runtime flags or disable hidden observer
subtrees manually.
`Tracer.in_memory`, `Logger.in_memory`, and `Meter.in_memory` remove bespoke
mutable capability collectors from tests and diagnostics while keeping dumps and
retention bounded by Eta-owned helper APIs.
`Effect.daemon` plus `Runtime.drain` removes manual daemon fiber bookkeeping
from runtime-owned finite background work and gives tests and shutdown code an
explicit point to wait for active daemon work.
`Resource.manual` and `Resource.refresh` remove manual mutable cache publishing
from caller-driven reload flows and keep last-good-value publication
resource-owned while returning refresh failures through the caller's typed error
channel.
`Effect.current_span`, `Effect.link_span`, and `Effect.named_kind` keep
producer/consumer relationships in tracer-native metadata instead of string
attributes that downstream exporters cannot interpret structurally.
`Effect.fn` keeps source-location span wrapping tied to compiler-provided
`__POS__` and `__FUNCTION__` values instead of forcing callers to format a
`loc` string and choose a span name manually. `Effect.here_attr` remains the
lower-level wrapper primitive for helpers that pass source positions through.
`Effect.with_error_renderer` keeps observability rendering separate from the
typed error channel: the same typed failure still reaches callers while span
status, exception-event messages, and finalizer diagnostics become meaningful.
`Effect.finally` keeps one-shot cleanup in Eta's lifecycle model instead of a
manual typed-success/failure wrapper. Cleanup runs on success, typed failure,
defect, and cancellation, and cleanup failures are represented as finalizer or
suppressed causes.
`Effect.name` and `Effect.collect_names` keep blueprint inspection tied to the
effect description itself instead of a parallel manual registry. The promoted
shape is deliberately documented as static preflight inspection: continuation
names are not forced just to collect names.
`Schedule` remains the retry/repeat policy surface. The promoted shape uses
`Effect.retry` with a composed schedule instead of a manual recursive loop,
manual result lifting, and ad hoc delay calculation.
`Mutable_ref` remains an application-owned shared-state surface. The promoted
shape uses `Mutable_ref.update_and_get` inside a synchronous leaf instead of
exposing a raw `Atomic.get` / `Atomic.compare_and_set` loop.
`Random` remains the deterministic helper surface over `Capabilities.random`.
The promoted shape uses named range/boolean helpers instead of hand-written
`Capabilities.random_float` arithmetic.
`Duration` remains the typed time surface. The promoted shape is one line
longer than raw millisecond integer math, but it keeps unit conversion,
non-negative clamping, scaling, comparison, runtime sleep bridging, and
formatting on one shared value instead of forcing callers to own ad hoc
millisecond plumbing.
`Log_level` remains the typed severity and threshold surface. The promoted
shape uses `Log_level.of_string` and `is_enabled` instead of reimplementing
case folding, rank tables, `All` / `Off` semantics, and OTLP mapping in
application code.
`Sampler` remains the trace-sampling policy surface. The promoted shape has the
same line count as manual hashing, but names the policy, clips ratio bounds,
and preserves parent-based sampling semantics in the same form interpreted by
the runtime.
`Trace_context` remains the W3C propagation surface. The promoted shape uses
validated extraction and `Effect.with_context` instead of manual traceparent
substring slicing, preserving sampled flags, tracestate, and baggage.
`Exit` and `Cause` remain the runtime outcome surface. The promoted boundary
uses `Exit.to_result` instead of manually matching every cause constructor, but
the runnable example proves that only `Ok` and single typed `Cause.Fail` exits
can faithfully become OCaml `result`; defects and finalizer failures stay in
the full cause tree.
`Runtime.run` remains the preferred application execution boundary. The
promoted shape uses `Runtime.run` directly instead of catching `run_exn` and
re-wrapping failures, preserving the same typed `Exit` channel that
`Exit.to_result` can later collapse deliberately.
Application service composition remains ordinary OCaml. The promoted shape
passes `clock` and `db` directly instead of looking them up in a dynamic service
bag, while the runnable example still uses Eta for effectful service
construction and cleanup.

## Decisions

### DX-1 - Add `Effect.sync_result`

Accepted. It is a pure shorthand over the existing contract: expected typed
leaf failures come from `result`, while exceptions remain defects. It reduces
boilerplate in resource acquisition/release, retrying calls, and stream
transforms without changing semantics.

### DX-2 - Add `Effect.with_resource`

Accepted as the friendly body-bounded name for existing
`Effect.acquire_use_release`. The implementation delegates to
`acquire_use_release`; it does not add new lifecycle behavior. The name works
well with `Eta.Syntax.(let@)` and avoids teaching new users to start with
`Effect.scoped (Effect.acquire_release ... |> Effect.bind ...)`.

### DX-3 - Add HTTP handler adapters

Accepted. `Server.Handler.of_sync`, `of_result`, and `of_effect` let simple HTTP
handlers start from ordinary OCaml functions while preserving Eta's runtime
boundary. `of_sync` and `of_result` evaluate under `Effect.sync` /
`Effect.sync_result`, so raised exceptions become Eta defects instead of
escaping handler construction.

### DX-4 - Do not hide `let*`

Accepted. This bucket does not introduce PPX or direct-style emulation. The
evidence suggests the larger win is removing explicit `Effect.bind` and repeated
leaf boilerplate, while keeping `let*` visible where user code is genuinely
sequencing effectful workflow.

## Verification

```sh
dune runtest test/api_dx --force
dune runtest test/core_common --force
nix develop -c dune runtest test/http --force
nix develop -c dune build @install
```

## Bucket 2 - User-facing example gate

Accepted documentation/example changes:

- Added `examples/quickstart.ml`.
- Added `examples/resource_retry.ml`.
- Added `examples/stream_decode.ml`.
- Added `examples/http_handlers.ml`.
- Added `examples/README.md` and a Dune `@examples` alias.
- Fixed `lib/stream/README.md` to use exported `Eta_stream.Stream.*`
  constructors.
- Updated the root README footgun to recommend `Effect.sync_result` for
  synchronous leaves that return `result`.

Evidence:

```sh
nix develop -c dune build @examples
_build/default/examples/quickstart.exe
_build/default/examples/resource_retry.exe
_build/default/examples/stream_decode.exe
_build/default/examples/http_handlers.exe
```

Observed output:

```text
quickstart:3
resource:primary:user:42
stream:ALPHA,BETA,GAMMA
health:200
user:200
user-default-error:400
```

The promoted examples use no explicit `Effect.bind` or `(>>=)` in user-facing
code. `let*` appears only in `quickstart.ml`, where it marks real dependent
effect sequencing. `let@` appears only in `resource_retry.ml`, where it marks
the lexical resource lifetime created by `Effect.with_resource`.

### DX-5 - Do not add an Eio one-shot runner yet

Deferred. The current promoted example corpus repeats the Eio application
boundary:

```ocaml
Eio_main.run @@ fun stdenv ->
Eio.Switch.run @@ fun sw ->
let rt = Eta_eio.Runtime.create ~sw ~clock:(Eio.Stdenv.clock stdenv) () in
...
```

That repetition is real, and it became more visible as the corpus grew to
sixty-four API-DX areas. It still does not justify a production `Eta_eio`
one-shot runner. The examples use the explicit runtime value to own clocks,
sleep/random capabilities, tracer/logger/meter choices, daemon draining, and
blocking pools. A one-shot convenience runner also would not remove the
`Eio_main.run` / `Eio.Switch.run` boundary unless `eta_eio` started depending on
`eio_main`, which would change the package boundary for ordinary `eta_eio`
users.

Existing `eta_utop` already owns the opposite tradeoff for interactive sessions:
it depends on `eio_main` and exposes `Eta_utop.run`, `run_exn`, and
`with_runtime`. Revisit a production runner only if larger application examples
show a stable application-owned runner shape that preserves explicit capability
injection and shutdown/drain ownership.

## Bucket 3 - CLI/test examples and guarded metric gate

Accepted example/test changes:

- Added `examples/cli_business.ml`.
- Added `examples/workflow_test.ml`.
- Changed `test/api_dx/api_dx_examples.ml` from a print-only executable into a
  Dune test gate that fails if proposed snippets expose explicit
  `Effect.bind` / `(>>=)` or lose their expected `let*` / `let@` shape.

Evidence:

```sh
dune runtest test/api_dx --force
nix develop -c dune build @examples
nix develop -c dune runtest examples --force
_build/default/examples/cli_business.exe
```

Observed new output:

```text
cli:user:42
```

`examples/workflow_test.ml` covers the test-code scenario with `eta_test`:
virtual time, typed failure assertions, `Effect.timeout_as`, and
`Effect.delay`. It uses no explicit `Effect.bind`; `let*` appears only where the
test program sequences parse then lookup.

`examples/cli_business.ml` covers a small CLI/business workflow. It keeps pure
argument parsing as `Effect.from_result`, uses `Effect.sync_result` for the
retrying leaf request, and uses `let*` for real dependent workflow sequencing.
No production API was added in this bucket: the new examples exercise the
bucket-1 API without exposing a new repeated rough edge.

## Bucket 4 - Minimum-surface audit

Accepted documentation changes:

- Added `docs/api-dx.md` as the current preferred application style and
  minimum-surface evidence guide.
- Linked it from the root README.
- Added `test/api_dx/api_dx_surface.ml`, a Dune test that scans promoted
  example sources and selected user-facing docs for explicit `Effect.bind` /
  `(>>=)`.
- Updated public `Effect.sync` documentation to point synchronous `result`
  leaves at `Effect.sync_result`.
- Documented `Effect.bind`, `Effect.(>>=)`, and `Supervisor.Scope.bind` as
  primitive/advanced surfaces, with `let*` as the preferred user-facing
  spelling.
- Updated `docs/services.md`, `docs/background-work.md`,
  `docs/tutorial-eta-otel.md`, `docs/tutorial-eta-ai.md`, and
  `lib/sql/README.md` away from user-facing explicit `Effect.bind` examples.

Findings:

- Explicit `Effect.bind` is not needed in the user examples or preferred docs.
  It remains justified as the primitive under `Eta.Syntax` and for internal /
  advanced combinator code.
- The no-explicit-bind surface claim is now guarded by both snippet metrics and
  source/doc scanning under `dune runtest test/api_dx --force`.
- `Effect.acquire_use_release` is doc-dominated by `Effect.with_resource`, but
  not proven removable.
- `Effect.acquire_release` plus `Effect.scoped` remains justified for lifetimes
  wider than one callback body.
- `Effect.sync`, `Effect.sync_result`, and `Effect.from_result` each have a
  distinct role; none is proven removable.
- A production one-shot `eta_eio` runner is still deferred after rechecking the
  larger example corpus. Explicit runtime ownership remains part of Eta's
  lifecycle story, while `eta_utop` already owns the interactive convenience
  tradeoff.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune build @examples
nix develop -c dune runtest examples --force
nix develop -c dune build @install
nix develop -c dune runtest --force
```

All passed. `nix develop -c dune build @doc` was also attempted and failed in
the current workspace with odoc `_unknown_` CMT/CMti errors across multiple
packages (`eta`, `eta_redacted`, `eta_router`, `eta_sql_dsl`, `ppx_eta`). The
failure is not specific to the new API-DX docs, and `@install` validates the
edited public interfaces.

## Bucket 5 - Effect surface audit

Accepted evidence/documentation changes:

- Added `.scratch/eta_research/api_dx/effect_surface.md`.
- Added an `Effect Surface Map` section to `docs/api-dx.md`.

Findings:

- `Effect.mli` currently exposes 74 `val` entries.
- The preferred application style is smaller than the raw signature: leaves,
  syntax-backed sequencing, typed recovery, time/retry, resource helpers,
  structured concurrency, and observability.
- `name` and `collect_names` are classified as diagnostic/preflight surface,
  not first-contact workflow API.
- `bind`, `(>>=)`, `seq`, `concat`, `acquire_use_release`, `supervisor_*`,
  and `Expert` are classified as low-level or advanced surface, not
  first-contact API.
- No public `Effect` value is proven removable by the current evidence. The
  current defensible action is documentation demotion plus guardrails, not API
  deletion.

## Bucket 6 - Blocking typed leaves

Accepted additive API changes:

- Added `Eta_blocking.run_result`.
- Added `Eta_blocking.run_result_timeout`.
- Kept `Eta_blocking.result` and `Eta_blocking.result_timeout` as short aliases.
- Added `examples/blocking_result.ml`.
- Extended the API-DX metric gate with a blocking current/proposed pair.
- Updated `README.md`, `docs/concurrency-guide.md`, `docs/zio-boundaries.md`,
  and `docs/api-dx.md` to teach `run_result` as the blocking analogue of
  `Effect.sync_result`.

Findings:

- The pattern `Eta_blocking.run ... |> Effect.bind Effect.from_result` is the
  blocking analogue of the synchronous leaf boilerplate fixed by
  `Effect.sync_result`.
- `Eta_blocking.result` already had the right behavior, but the name did not
  say "run this blocking result-returning leaf" as clearly as `run_result`.
- No deletion is justified. The old names remain aliases; new examples and docs
  prefer the verb-first spelling.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune build @examples
nix develop -c dune runtest test/blocking_eio --force
nix develop -c dune runtest examples --force
nix develop -c dune build @install
nix develop -c dune runtest --force
```

Observed blocking metric:

```text
blocking,current,lines=2,effect_bind=1,let_star=0,let_at=0,from_result=1
blocking,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

## Bucket 7 - Supervisor nursery entry

Accepted example/documentation changes:

- Added `examples/supervisor_scope.ml`.
- Added the supervisor example to the promoted-surface scanner.
- Updated `README.md` and `docs/api-dx.md` to explain that
  `Supervisor.scoped { run = ... }` is intentionally heavier than ordinary
  callback helpers because it carries the rank-2 scope token.

No additive supervisor API was accepted in this bucket.

Findings:

- The candidate shape was a direct helper like `Supervisor.with_scope @@ fun sup
  -> ...`, intended to hide the `{ run = ... }` record.
- OCaml rejected the direct explicit-polymorphic function parameter spelling in
  the implementation/interface experiment. Replacing the rank-2 record with a
  regular function would weaken the non-escaping child-handle guarantee.
- A manual escape experiment that tried to return a child handle from
  `Supervisor.scoped` was rejected by the compiler because the body function was
  less general than the required rank-2 field. That is the desired lifecycle
  invariant.
- Therefore the current best user shape is to keep `Supervisor.scoped { run =
  ... }` for handle-owning nurseries, use `Supervisor.Scope.(let*)` inside the
  body, and prefer `Effect.with_background` when no child handle is needed.

Manual diagnostic:

```text
This field value has type
  ('a, 'b) Eta.Supervisor.t ->
  ('a, ('a, 'b, unit) Eta.Supervisor.child, 'b) Eta.Supervisor.Scope.t
which is less general than
  's. ('s, 'c) Eta.Supervisor.t -> ('s, 'd, 'c) Eta.Supervisor.Scope.t
```

Verification note:

- `test/eta/soundness/run.sh` is not currently a usable gate in this workspace:
  it also reports pre-existing unrelated failures such as
  `effect_private_blocking_submit_negative.ml` failing for an unbound private
  module and several portable-closure fixtures compiling unexpectedly. The
  supervisor escape fixture was not added to that suite.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune build @examples
nix develop -c dune runtest test/runtime_eio --force
nix develop -c dune build @install
nix develop -c dune exec examples/supervisor_scope.exe
```

Observed example output:

```text
supervisor:failures:1
```

## Bucket 8 - Package README guardrail

Accepted test/documentation changes:

- Expanded `test/api_dx/api_dx_surface.ml` beyond the initial docs to include
  preferred package READMEs and package-level user docs.
- Added `examples/README.md` to the scanner after rewording its policy sentence
  so it no longer contains a literal low-level bind token.
- Updated `docs/api-dx.md` to clarify that archived research notes, audit logs,
  probes, and `docs/api-dx.md` itself are excluded because they discuss
  low-level names as subject matter rather than recommended style.

Findings:

- Package READMEs for `eta_ai`, AI providers, `eta_http`, `eta_otel`,
  `eta_par`, `eta_schema`, `eta_schema_test`, `eta_sql`, `eta_stream`, and
  `eta_test` currently do not need explicit `Effect.bind`, `Eta.Effect.bind`,
  or `(>>=)` to teach their preferred API.
- The next deletion-oriented pass still has no new deletion proof. This bucket
  proves a larger recommended surface can stay free of explicit bind without
  deleting the primitive.

Verification:

```sh
dune runtest test/api_dx --force
```

## Bucket 9 - Observability blueprint example

Accepted example/documentation/test changes:

- Added `examples/observability.ml`.
- Added the observability example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with an observability current/proposed pair.
- Updated `docs/api-dx.md` and `examples/README.md` to include observability as
  a promoted application shape.

No new observability combinator was accepted in this bucket.

Findings:

- The existing public surface is already enough to express an observable Eta
  workflow without explicit bind: `Effect.named`, `Effect.log`, `Effect.event`,
  `Effect.with_result_attrs`, and `Effect.metric_update`.
- The example proves Eta's "program as blueprint" strength for observability:
  one interpreted effect produces a span, span result attributes, a span event,
  a structured log record correlated to the span, and a metric point.
- The current/proposed metric pair shows the DX issue is not missing semantics;
  it is spelling. Syntax-backed sequencing keeps the ordered signal emission
  readable without adding another API layer.
- No deletion is justified. The low-level primitive remains for advanced and
  internal code; the promoted surface stays free of direct bind usage.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/observability.exe
```

Observed example output:

```text
observability:user:42 spans=1 logs=1 metrics=1
```

## Bucket 10 - Background lifecycle and foreground concurrency

Accepted example/documentation/test changes:

- Added `examples/background_lifecycle.ml`.
- Added the background lifecycle example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a background current/proposed pair.
- Updated `docs/api-dx.md` and `examples/README.md` to include
  `Effect.with_background` and `and*` as promoted application shape evidence.

No new background or concurrency API was accepted in this bucket.

Findings:

- The existing public surface is enough for a body-owned background child plus
  independent foreground work: `Effect.with_background`, `Effect.named`,
  `Effect.acquire_release`, `Effect.sync_result`, and `Eta.Syntax.(and*)`.
- The current/proposed metric pair shows the visible-bind issue is spelling:
  the bind-heavy spelling has one explicit `Effect.bind`; the promoted spelling
  has zero and keeps the body workflow explicit with `let*` and `and*`.
- The runnable example deliberately uses a finite background child so the
  promoted example is deterministic and fast. Cancellation-specific behavior
  remains covered by the existing runtime tests; the executable is API evidence,
  not a replacement for the lower-level semantics suite.
- No deletion is justified. `Effect.par` remains the semantic primitive;
  `and*` is the preferred application spelling for independent concurrent
  values.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/background_lifecycle.exe
```

Observed example output:

```text
background:user:left,user:right stopped=true
```

## Bucket 11 - Wider scoped resource handles

Accepted example/documentation/test changes:

- Added `examples/scoped_resource.ml`.
- Added the scoped-resource example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a scoped-resource current/proposed pair.
- Updated `docs/api-dx.md` and `examples/README.md` to include
  `Effect.acquire_release` plus `Effect.scoped` as runnable application-shape
  evidence.

No new resource API was accepted in this bucket.

Findings:

- `Effect.with_resource` is the preferred body-bounded bracket, but it does not
  dominate the wider scoped-handle shape.
- `Effect.acquire_release` lets a setup function register cleanup with the
  current scope and return a live handle to later effects. `Effect.scoped`
  defines the boundary that releases that handle.
- The runnable example proves the handle stays open through the scoped body and
  is released after the scope exits.
- The current/proposed metric pair shows the visible-bind issue is spelling:
  the bind-heavy scoped form has one explicit `Effect.bind`; the promoted form
  uses syntax-backed `let*`/`and*` and keeps `Effect.acquire_release` plus
  `Effect.scoped` visible.
- No deletion is justified. `Effect.acquire_use_release` remains doc-dominated
  by `Effect.with_resource` for body-bounded use, but `Effect.acquire_release`
  and `Effect.scoped` remain semantically distinct.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/scoped_resource.exe
timeout 60s nix develop -c dune build @examples
```

Observed example output:

```text
scoped:main:config,main:profile released=true
```

## Bucket 12 - Bounded batch concurrency and settled outcomes

Accepted example/documentation/test changes:

- Added `examples/batch_concurrency.ml`.
- Added the batch concurrency example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a batch current/proposed pair.
- Updated `docs/api-dx.md` and `examples/README.md` to include bounded fan-out
  and collected branch outcomes as promoted evidence.

No new concurrency API was accepted in this bucket.

Findings:

- `Eta.Syntax.(and*)` is the compact spelling for two independent effects, but
  it does not dominate batch fan-out.
- `Effect.for_each_par_bounded` is the clearer public shape when a workflow maps
  an effectful worker over many inputs with an explicit concurrency cap.
- `Effect.all_settled` is the clearer public shape when the caller needs every
  branch outcome without failing the outer effect.
- The current/proposed metric pair shows the bind-heavy recursive batch form has
  one explicit `Effect.bind`; the promoted form uses one workflow `let*`,
  `Effect.for_each_par_bounded`, and `Effect.all_settled` with zero explicit
  bind calls.
- No deletion is justified. The batch combinators remain semantic capabilities,
  not convenience aliases over `and*`.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/batch_concurrency.exe
```

Observed example output:

```text
batch:alpha:user:alpha,beta:user:beta,gamma:user:gamma settled=2/1
```

## Bucket 13 - Racing mirrors

Accepted example/documentation/test changes:

- Added `examples/race_mirror.ml`.
- Added the race example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a race current/proposed pair.
- Updated `docs/api-dx.md` and `examples/README.md` to include first-success
  racing as promoted evidence.

No new race API was accepted in this bucket.

Findings:

- `Effect.all_settled` is useful when the caller needs all outcomes, but it is
  not the right API when the first successful mirror should win.
- `Effect.race` is the direct public shape for first-success concurrency. The
  example proves a failing primary branch does not prevent a successful
  secondary branch from winning.
- The current/proposed metric pair shows the all-settled workaround needs an
  explicit `Effect.bind` to inspect outcomes; the promoted `Effect.race` shape
  is a one-line composition with zero explicit bind calls.
- No deletion is justified. `race` remains a semantic capability distinct from
  `all`, `all_settled`, `par`, and syntax-backed two-way `and*`.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/race_mirror.exe
```

Observed example output:

```text
race:secondary:/users/42
```

## Bucket 14 - Typed error boundaries

Accepted example/documentation/test changes:

- Added `examples/typed_error_boundary.ml`.
- Added the typed-error boundary example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a typed_error current/proposed pair.
- Updated `docs/api-dx.md` and `examples/README.md` to include domain-to-boundary
  error mapping as promoted evidence.

No new typed-error API was accepted in this bucket.

Findings:

- `catch` is useful for recovery, but it is not the clearest spelling when the
  caller wants to observe a domain failure and translate the error channel at a
  boundary.
- `Effect.tap_error` observes the domain error without changing the channel.
- `Effect.map_error` translates the channel to the boundary error while
  preserving defects, interruption, and finalizer diagnostics through the
  existing runtime path.
- The current/proposed metric pair shows the catch-and-rethrow workaround needs
  one explicit `Effect.bind`; the promoted `tap_error`/`map_error` shape keeps
  domain sequencing in one `let*` and uses zero explicit bind calls.
- No deletion is justified. `map_error` and `tap_error` remain typed-error
  boundary capabilities, not reduction candidates.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/typed_error_boundary.exe
```

Observed example output:

```text
typed-error:observed=not-found:missing api=not-found:missing
```

## Bucket 15 - Abortable admission control

Accepted example/documentation/test changes:

- Added `examples/admission_control.ml`.
- Added the admission-control example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with an admission current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include scoped semaphore admission as promoted evidence.

No new semaphore API was accepted in this bucket.

Findings:

- Raw `Semaphore.acquire`/`release` are enough to build admission control, but
  only if callers also implement a claimed-permit flag, abort race, and
  finalizer path correctly.
- `Semaphore.with_permits_or_abort` is the better application API when permit
  acquisition races an abort signal. It preserves the lifecycle invariant that
  a claimed permit is released on success, typed failure, defect, outer
  cancellation, or discarded race result.
- `Semaphore.with_permits` remains the better application API for lexical
  permit ownership without an abort signal.
- The current/proposed metric pair shows the manual protocol is thirteen lines
  with one explicit `Effect.bind`; the promoted helper is one line with zero
  explicit bind calls and no user-visible `Atomic`/finalizer protocol.
- No deletion is justified. Raw `acquire` and `release` remain low-level
  capabilities for custom protocols, tests, and internals such as pools; they
  should not be first-contact application style.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/admission_control.exe
```

Observed example output:

```text
admission:accepted:alpha:available=0,busy:beta available=1 waiting=0
```

## Bucket 16 - Runtime-owned cached resources

Accepted example/documentation/test changes:

- Added `examples/cached_resource.ml`.
- Added the cached-resource example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a cached_resource current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include runtime-owned cached resources as promoted evidence.

No new resource API was accepted in this bucket.

Findings:

- A caller can approximate cached refresh with `with_background`, `repeat`, a
  mutable ref, `catch`, and manual publishing, but that recreates an Eta-owned
  lifecycle protocol in application code.
- `Resource.auto` is the clearer application API when a resource should seed
  once, refresh on a schedule owned by the runtime, keep the last good value
  after refresh failure, record typed failures/defects, and expose those
  diagnostics through `Resource.failures`.
- The current/proposed metric pair shows the manual refresh loop is thirteen
  lines with three explicit `Effect.bind` calls; the promoted `Resource.auto`
  shape is three lines, one `let*`, and zero explicit bind calls.
- No deletion is justified. `Resource.manual` and `Resource.refresh` remain the
  caller-driven shape when scheduled refresh is not the desired lifecycle.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/cached_resource.exe
```

Observed example output:

```text
cached-resource:initial=v1:primary after-failure=v1:primary final=v2:secondary failures=1 observed=1
```

## Bucket 17 - Runtime-local connection pools

Accepted example/documentation/test changes:

- Added `examples/connection_pool.ml`.
- Added the pool example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a pool current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include runtime-local pools as promoted evidence.

No new pool API was accepted in this bucket.

Findings:

- A caller can approximate a tiny reusable connection cache with a semaphore,
  mutable idle slot, custom checkout function, and cleanup path, but that is a
  hand-rolled pool protocol.
- `Pool.create` plus `Pool.with_resource` is the clearer application API when
  runtime-local values should be bounded, reused across operations, returned to
  idle after success/failure/defect, observed through stats, and closed at
  shutdown.
- `Pool.shutdown` is part of the user-facing lifecycle, not just an internal
  cleanup hook: the promoted example proves the idle connection is closed and
  accounted for after shutdown.
- The current/proposed metric pair shows the hand-rolled idle-cache sketch is
  seventeen lines with two explicit `Effect.bind` calls; the promoted pool shape
  is seven lines, zero explicit bind calls, and uses syntax only for true
  sequencing.
- No deletion is justified. Plain `Effect.with_resource` remains right for
  one-shot resources; `Pool` remains a distinct semantic capability for bounded
  reuse and lifecycle ownership.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/connection_pool.exe
```

Observed example output:

```text
pool:conn:1:first,conn:1:second opened=1 idle-before=1 closed-after=1
```

## Bucket 18 - Scoped publish/subscribe subscriptions

Accepted example/documentation/test changes:

- Added `examples/pubsub_subscription.ml`.
- Added the pubsub example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a pubsub current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include scoped publish/subscribe subscriptions as promoted evidence.

No new pubsub API was accepted in this bucket.

Findings:

- `Pubsub.subscribe` is callback-shaped because the subscription lifetime is
  scoped to the callback body. If the subscription escaped, retained messages
  and receiver wakeups would need additional user-managed cleanup.
- `Eta.Syntax.(let@)` is the preferred user spelling for `subscribe`; it keeps
  the subscription lifetime visible without starting the workflow with explicit
  `Effect.bind`.
- The current/proposed metric pair shows callback/bind-heavy usage is eight
  lines with two explicit `Effect.bind` calls; the promoted `let@` shape is six
  lines with zero explicit bind calls.
- The runnable example proves a current subscriber receives the published
  message, typed close is observed through `Pubsub.recv`, and hub stats record
  one active subscriber and one received message inside the scope.
- No deletion is justified. `Pubsub.publish`, `Pubsub.recv`, `try_recv`,
  `close`, and `close_with_error` remain the message and lifecycle operations
  inside or around the scoped subscription.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/pubsub_subscription.exe
```

Observed example output:

```text
pubsub:published=1 first=created closed=closed:broker subscribers=1 received=1
```

## Bucket 19 - Bounded same-domain channels

Accepted example/documentation/test changes:

- Added `examples/bounded_channel.ml`.
- Added the channel example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a channel current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include bounded same-domain handoff as promoted evidence.

No new channel API was accepted in this bucket.

Findings:

- `Channel` is the right public shape when bounded backpressure is part of the
  contract. A plain queue does not force sender backpressure, and a semaphore
  plus mutable state would force users to reimplement close fences and waiter
  cleanup.
- `Channel.send` and `Channel.recv` remain direct message operations. The DX
  improvement is to teach them with syntax-backed producer/consumer workflows,
  not to hide them behind another helper.
- The current/proposed metric pair shows callback/bind-heavy producer and
  consumer code is sixteen lines with five explicit `Effect.bind` calls; the
  promoted syntax-backed shape is twelve lines and zero explicit bind calls.
- The runnable example proves capacity-one backpressure: the second sender is
  blocked while the buffer is full, both values drain FIFO, and typed close is
  reported after the buffered values are consumed.
- No deletion is justified. `try_send`, `try_recv`, `close`, and
  `close_with_error` remain the nonblocking and lifecycle operations around the
  blocking send/receive path.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/bounded_channel.exe
```

Observed example output:

```text
channel:first=first second=second closed=closed:done blocked=1/1 sent=2 received=2
```

## Bucket 20 - Unbounded same-domain queues

Accepted example/documentation/test changes:

- Added `examples/unbounded_queue.ml`.
- Added the queue example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a queue current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include unbounded same-domain handoff as promoted evidence.

No new queue API was accepted in this bucket.

Findings:

- `Queue` is the right public shape when buffered fan-in should not apply
  sender backpressure. A bounded `Channel` changes that contract, `Pubsub`
  changes it to fan-out/subscription ownership, and a semaphore plus mutable
  state would force users to reimplement close fences and receiver-waiter
  cleanup.
- `Queue.send` and `Queue.recv` remain direct message operations. The DX
  improvement is to teach them with syntax-backed FIFO workflows, not to hide
  them behind another helper.
- The current/proposed metric pair shows bind-heavy queue drain code is
  eighteen lines with seven explicit `Effect.bind` calls; the promoted
  syntax-backed shape is eleven lines and zero explicit bind calls.
- The runnable example proves unbounded buffering: three sends complete before
  any receive, all buffered values drain FIFO, and typed close is reported after
  the buffered values are consumed.
- No deletion is justified. `try_send`, `try_recv`, `close`, and
  `close_with_error` remain the nonblocking and lifecycle operations around the
  blocking send/receive path.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/unbounded_queue.exe
```

Expected example output:

```text
queue:first=alpha second=beta third=gamma closed=closed:done depth=3 waiting=0 sent=3 received=3
```

## Bucket 21 - Composed retry schedules

Accepted example/documentation/test changes:

- Added `examples/retry_schedule.ml`.
- Added the retry-schedule example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a schedule-retry current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include composed retry schedules as promoted evidence.

No new schedule API was accepted in this bucket.

Findings:

- `Schedule` is the right public shape when retry/repeat policy should be a
  reusable blueprint. A recursive retry loop forces users to own attempt
  counters, typed-result lifting, delay calculation, sleep placement, and
  jitter/random state.
- `Effect.retry` is the right interpreter entrypoint for application retry
  workflows. `Schedule.start` and `Schedule.next` remain visible for tests,
  diagnostics, previews, and alternative interpreters.
- The current/proposed metric pair shows a manual retry loop is nine lines
  with one explicit `Effect.bind` call and one `Effect.from_result`; the
  promoted schedule-backed shape is six lines with zero explicit bind calls and
  zero `Effect.from_result`.
- The runnable example passes a seeded random token and custom runtime sleep
  function. It proves the sleeps chosen by `Effect.retry` match the pure
  `Schedule.start` preview for the same seed, without actually waiting.
- No deletion is justified. `Schedule.recurs`, `exponential`, `jittered`,
  `start`, `next`, and `next_delay` remain the recurrence description,
  interpreter-driver, and preview surfaces.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/retry_schedule.exe
```

Observed example output:

```text
retry-schedule:payload=ok:3 attempts=3 sleeps=17,22 expected=17,22
```

## Bucket 22 - Application-owned shared mutable state

Accepted example/documentation/test changes:

- Added `examples/mutable_ref_state.ml`.
- Added the mutable-ref example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a mutable-ref current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include application-owned shared mutable state as promoted evidence.

No new mutable-ref API was accepted in this bucket.

Findings:

- `Mutable_ref` is the right public shape when application code owns a small
  shared cell and needs atomic update semantics inside a synchronous leaf.
  `Effect`, `Resource`, `Pool`, `Queue`, and `Channel` own different protocols:
  lifecycle, reuse, handoff, backpressure, or close fences.
- `Mutable_ref.update_and_get` keeps the CAS retry loop out of application
  code. It does not make Eta own the state; callers still allocate the cell,
  pass it to the workflow, and decide its lifetime.
- The current/proposed metric pair shows a raw `Atomic.get` /
  `Atomic.compare_and_set` update loop is ten lines; the promoted
  `Mutable_ref.update_and_get` shape is five lines. Neither shape needs
  explicit `Effect.bind`, so the evidence here is API clarity rather than bind
  removal.
- The runnable example proves shared state updates across a bounded concurrent
  workflow, returns a final snapshot, and resets the application-owned cell
  with `Mutable_ref.get_and_set`.
- No deletion is justified. `make`, `get`, `set`, `update`, `update_and_get`,
  `get_and_set`, and `compare_and_set` remain the small named shared-state
  surface over `Atomic.t`.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/mutable_ref_state.exe
```

Observed example output:

```text
mutable-ref:processed=4 bytes=480 max=256 reset=0 snapshots=4
```

## Bucket 23 - Deterministic portable random helpers

Accepted example/documentation/test changes:

- Added `examples/deterministic_random.ml`.
- Added the deterministic-random example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a random current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include deterministic random helpers as promoted evidence.

No new random API was accepted in this bucket.

Findings:

- `Random` is the right public shape when application code needs deterministic
  draws over Eta's portable random token. `Capabilities.random_float` remains
  the primitive, but direct range and boolean math is too easy to duplicate and
  subtly mis-specify in application code.
- `Capabilities.random_of_seed` and `random_set_seed` remain visible because
  deterministic replay is part of the runtime story: the same token type drives
  jittered schedules and user-visible random helpers.
- The current/proposed metric pair shows manual `random_float` range and
  boolean math is seven lines; the promoted `Random.int_in_range` /
  `Random.float_in_range` / `Random.bool` shape is four lines. Neither shape
  needs explicit `Effect.bind`, so the evidence here is API clarity and
  deterministic replay rather than bind removal.
- The runnable example proves same-seed replay across integer, float, boolean,
  shuffle, weighted-choice, and list-sample helpers, including reset through
  `Capabilities.random_set_seed`.
- No deletion is justified. `Capabilities.random_float` remains the primitive
  for low-level/runtime code; `Random.*` remains the application helper surface.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/deterministic_random.exe
```

Observed example output:

```text
random:dice=13 ratio=2.223 coin=true shuffle=2,4,1,3 weighted=c sample=40 replay=true
```

## Bucket 24 - Trace sampling policies

Accepted example/documentation/test changes:

- Added `examples/trace_sampling.ml`.
- Added the trace-sampling example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a sampler current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include trace sampling as promoted evidence.

No new sampler API was accepted in this bucket.

Findings:

- `Sampler` is the right public shape when application/runtime configuration
  needs trace sampling policy. A manual `Hashtbl.hash trace_id` check can match
  line count for a narrow ratio sampler, but it does not name the policy,
  centralize ratio clipping, or carry parent-based semantics.
- `Sampler.sample` remains visible for tests, diagnostics, and alternative
  interpreters. Ordinary runtime users usually pass `?sampler` to
  `Runtime.create` / `Eta_eio.Runtime.create`.
- The current/proposed metric pair is four lines in both shapes and uses no
  explicit `Effect.bind`. The accepted reason is API clarity and semantic
  ownership, not line-count reduction.
- The runnable example proves deterministic same-trace ratio decisions, clipped
  all-on/all-off ratio behavior, and parent-based root/child decisions.
- No deletion is justified. `always_on`, `always_off`, `ratio`,
  `parent_based`, and `sample` remain the small trace-sampling policy surface.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/trace_sampling.exe
```

Observed example output:

```text
sampler:ratio=true same-trace=true all-on=true all-off=false root=false child=true
```

## Bucket 25 - W3C trace context propagation

Accepted example/documentation/test changes:

- Added `examples/trace_context_boundary.ml`.
- Added the trace-context example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a trace-context current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include W3C trace context propagation as promoted evidence.

No new trace-context API was accepted in this bucket.

Findings:

- `Trace_context.extract` plus `Effect.with_context` is the right boundary
  shape when inbound headers may carry W3C trace context. Manual
  `traceparent` substring extraction can recover trace/span IDs but loses
  validation, sampled flags, tracestate, and baggage.
- `Effect.with_external_parent` remains the compatibility shape when a boundary
  truly has only trace and span IDs. It should not be the preferred API for
  HTTP-style boundaries that carry full W3C propagation headers.
- The current/proposed metric pair shows manual `traceparent` extraction is six
  lines; the promoted `Trace_context.extract` / `Effect.with_context` shape is
  three lines. Neither shape needs explicit `Effect.bind`, so the evidence is
  propagation correctness and API clarity.
- The runnable example extracts inbound headers, runs a named effect under the
  external context, verifies `Effect.current_context` preserves tracestate and
  baggage, checks the tracer span external parent, and injects outbound headers.
- No deletion is justified. `Trace_context.make`, `extract`, `inject`, and
  `sampled` remain the small dependency-free W3C propagation surface.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/trace_context_boundary.exe
```

Observed example output:

```text
trace-context:sampled=true trace=4bf92f3577b34da6a3ce929d0e0e4736 parent=t61rcWkgMzE baggage=acme spans=1
```

## Bucket 26 - Runtime exit and cause boundary

Accepted example/documentation/test changes:

- Added `examples/exit_cause_boundary.ml`.
- Added the exit/cause example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with an exit_cause current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include runtime outcome boundaries as promoted evidence.

No new exit/cause API was accepted in this bucket.

Findings:

- `Exit.to_result` is the right adapter shape only when a boundary deliberately
  accepts the information loss of converting Eta exits to ordinary OCaml
  `result`.
- `Exit` and `Cause` are not removable in favor of `result` or exceptions. The
  runnable example proves that a typed `Cause.Fail` can become `Error`, while a
  defect and a successful-body finalizer failure cannot.
- The current/proposed metric pair shows hand-written conversion over the
  runtime cause constructors is seven lines; the promoted `Exit.to_result`
  shape is one line. Neither shape needs explicit `Effect.bind`, so the
  evidence is boundary clarity and avoiding repeated cause matching.
- `Exit.pp`, `Cause.pp`, `Cause.Finalizer`, and `Cause.Suppressed` remain part
  of the visible diagnostic surface for callers that must preserve runtime
  failures rather than collapse them to `result`.
- No deletion is justified. `Exit.to_result` is a convenience adapter, not a
  replacement for the full runtime exit channel.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/exit_cause_boundary.exe
```

Observed example output:

```text
exit-cause:typed=result:bad input defect=die finalizer=close-failed
```

## Bucket 27 - Typed duration budgets

Accepted example/documentation/test changes:

- Added `examples/duration_budget.ml`.
- Added the duration example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a duration current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include typed duration budgets as promoted evidence.

No new duration API was accepted in this bucket.

Findings:

- `Duration` is the right public shape for retry, timeout, delay, test-clock,
  and runtime sleep budgets that would otherwise be raw milliseconds.
- The current/proposed metric pair shows raw integer math is seven lines; the
  promoted typed `Duration` shape is eight lines. The accepted reason is not
  line-count reduction. It is unit clarity, non-negative clamping, overflow
  checks in constructors/arithmetic, and one shared bridge to runtime sleep via
  `Duration.to_ms` / `to_seconds_float`.
- The runnable example derives retry delays with `Duration.times`, `scale`, and
  `clamp`; derives an IO budget with `subtract` and `scale`; validates policy
  bounds with `between`; and renders values with `Duration.pp`.
- No deletion is justified. `Duration.ms`, `seconds`, arithmetic helpers,
  bounds helpers, conversion helpers, and `pp` remain the small typed time
  vocabulary shared by Eta time surfaces.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/duration_budget.exe
```

Observed example output:

```text
duration:delays=187,375,750,1500,2000 average=962ms io=2375ms within=true
```

## Bucket 28 - Runtime execution boundary

Accepted example/documentation/test changes:

- Added `examples/runtime_boundary.ml`.
- Added the runtime-boundary example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a runtime_boundary current/proposed
  pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include runtime execution boundaries as promoted evidence.

No new runtime API was accepted in this bucket.

Findings:

- `Runtime.run` is the right public shape for application and adapter
  boundaries that need to inspect success, typed failure, defect, interruption,
  or cleanup diagnostics.
- `Runtime.run_exn` remains useful for tests and top-level programs that cannot
  recover. It preserves successful values, but on non-success it leaves the
  typed error channel and raises instead.
- The current/proposed metric pair shows catching and re-wrapping `run_exn`
  takes three lines; direct `Runtime.run` is one line. The stronger reason is
  semantic: `run` preserves the full `Exit`, while the `run_exn` recovery shape
  invents a new failure channel from rendered exception text.
- No deletion is justified. `run_exn` remains the explicit collapse helper, but
  it should not be the preferred example shape when failures are inspected.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/runtime_boundary.exe
```

Observed example output:

```text
runtime-boundary:run=exit:quota run_exn_ok=ready run_exn_error=raised
```

## Bucket 29 - Ordinary service composition

Accepted example/documentation/test changes:

- Added `examples/service_composition.ml`.
- Added the service-composition example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a service current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include ordinary service composition as promoted evidence.

No new service API was accepted in this bucket.

Findings:

- Application services should be ordinary OCaml values. Pass records, modules,
  functions, or closures explicitly; use Eta only for effectful construction,
  cleanup, and runtime interpretation.
- The current/proposed metric pair shows a dynamic service-bag lookup is six
  lines; the promoted explicit dependency leaf is one line. Neither shape
  needs explicit `Effect.bind`, so the evidence is service-shape clarity, not
  monadic syntax.
- Runtime service keys remain useful for optional Eta packages that attach
  backend-owned services to an interpreter, such as blocking defaults or HTTP
  client runtimes. They are not the application dependency-injection API.
- No deletion is justified. `Runtime_contract.create_service_key`,
  `Runtime_contract.Service`, and `Effect.Expert.runtime_service` remain
  advanced package-extension hooks, while application examples should not teach
  a Layer/Context-style environment.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/service_composition.exe
```

Observed example output:

```text
service-composition:alice=alice@42 bob=bob@42 released=true
```

## Bucket 30 - Log-level policy boundaries

Accepted example/documentation/test changes:

- Added `examples/log_level_policy.ml`.
- Added the log-level example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a log_level current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include log-level policy boundaries as promoted evidence.

No new log-level API was accepted in this bucket.

Findings:

- `Log_level` is the right public shape for log threshold parsing, filtering,
  rendering, and OTLP severity-number mapping.
- The current/proposed metric pair shows an ad hoc string/rank parser is nine
  lines; the promoted `Log_level.of_string` / `is_enabled` shape is three
  lines. Neither shape needs explicit `Effect.bind`.
- The runnable example proves case-insensitive parsing, `Warn` threshold
  filtering, `Off` and `All` threshold semantics, `pp`, `to_otel_severity`, and
  `of_otel_severity`.
- No deletion is justified. Raw strings and OTLP integers remain boundary
  formats, but application policy should use `Log_level.t`.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/log_level_policy.exe
```

Observed example output:

```text
log-level:threshold=WARN enabled=WARN,ERROR,FATAL otel_warn=13 severity18=ERROR off=false all=true
```

## Bucket 31 - Lazy metric batching

Accepted example/API/documentation/test changes:

- Exposed the existing internal metric batch representation through an abstract
  `Effect.metric` descriptor builder.
- Exposed `Effect.metric_updates` for related observations that should share
  one runtime timestamp.
- Exposed `Effect.metric_updates_lazy` for hot paths where metric snapshots and
  allocation should happen only when the runtime has a meter.
- Added `examples/metric_batching.ml`.
- Added the metric-batching example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a metric_batch current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include lazy metric batching as promoted evidence.

No observability deletion was accepted in this bucket.

Findings:

- `Effect.metric_update` remains the right public shape for a single metric.
  It is not superseded by batching.
- The current/proposed metric pair shows repeated single updates take nine
  lines and four `let*` sequencing points; the lazy batch is eight lines in the
  expanded snippet and zero sequencing points. The stronger reason is runtime
  ownership: the metric snapshot thunk is not called at all when no meter is
  installed.
- The runnable example proves the disabled-runtime path performs zero batch
  builds and zero stats snapshots, while the enabled-runtime path records four
  related gauge points.
- This supports Eta's blueprint claim: metric code can remain in the effect
  description, while the interpreter decides whether the observation work is
  needed. Application code does not need to pass or branch on
  `Runtime.metrics_enabled`.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/metric_batching.exe
```

Observed API-DX output:

```text
metric_batch,current,lines=9,effect_bind=0,let_star=4,let_at=0,from_result=0
metric_batch,proposed,lines=8,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
metric-batching:disabled_builds=0 enabled_points=4 active=3
```

## Bucket 32 - Observability controls

Accepted example/documentation/test changes:

- Added `examples/observability_controls.ml`.
- Added the observability-controls example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with an observability_controls
  current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include tracing guards, lazy attributes, and suppressed observer subtrees
  as promoted evidence.

No new observability API was accepted in this bucket.

Findings:

- This is not a line-count win: the current sketch is five lines and the
  proposed blueprint is nine lines. The current sketch is shorter because it
  assumes an external `tracing_enabled` boolean and does not express
  observer/exporter recursion suppression as runtime interpretation.
- `Effect.is_tracing_enabled` keeps the enabled check inside the effect
  interpreter, so application code does not need to pass runtime flags through
  ordinary business functions.
- `Effect.annotate_all_lazy` avoids constructing expensive attributes when no
  tracer is installed.
- `Effect.suppress_observability` lets observer/exporter subtrees call Eta code
  without recursively producing spans, logs, or metrics, while preserving typed
  errors, defects, and cleanup semantics.
- No deletion is justified. These controls are advanced enough that they should
  not dominate the first tutorial, but they are core to Eta's runtime-owned
  observability story.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/observability_controls.exe
```

Observed API-DX output:

```text
observability_controls,current,lines=5,effect_bind=1,let_star=0,let_at=0,from_result=0
observability_controls,proposed,lines=9,effect_bind=0,let_star=3,let_at=0,from_result=0
```

Observed example output:

```text
observability-controls:disabled_trace=false disabled_attrs=0 visible_spans=1 hidden_logs=0 hidden_metrics=0
```

## Bucket 33 - Observability sink helpers

Accepted example/documentation/test changes:

- Added `examples/observability_sinks.ml`.
- Added the observability-sinks example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with an observability_sinks
  current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include built-in in-memory observability sinks as promoted evidence.

No new sink API was accepted in this bucket.

Findings:

- `Tracer.in_memory`, `Logger.in_memory`, and `Meter.in_memory` are the right
  public shape for tests and bounded diagnostics that need runtime-compatible
  observability sinks.
- The current/proposed metric pair shows hand-written logger/meter capability
  collectors take fourteen lines; the promoted built-in sink setup takes eight
  lines and uses no custom object protocol or raw mutable list collector.
- The runnable example proves the three sinks work together through
  `Eta_eio.Runtime.create`, logs are linked to trace/span ids, metrics are
  captured with attributes, and `Tracer.retain_recent` bounds retained spans to
  the latest one.
- No deletion is justified. `Logger.noop`, `Meter.noop`, and `Tracer.noop`
  remain disabled-sink capabilities; the in-memory helpers remain the test and
  diagnostics shape.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/observability_sinks.exe
```

Observed API-DX output:

```text
observability_sinks,current,lines=14,effect_bind=0,let_star=0,let_at=0,from_result=0
observability_sinks,proposed,lines=8,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
observability-sinks:spans=1 logs=2 metrics=2 retained=second
```

## Bucket 34 - Runtime daemon drain

Accepted example/documentation/test changes:

- Added `examples/daemon_drain.ml`.
- Added the daemon-drain example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a daemon_drain current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to distinguish runtime-owned daemon lifecycle from body-owned background
  lifecycle.

No new lifecycle API was accepted in this bucket.

Findings:

- `Effect.daemon` is not the same contract as `Effect.with_background`.
  `with_background` belongs to one lexical body and is cancelled when that body
  returns. `daemon` is for runtime-owned finite infrastructure work started
  from an Eta blueprint.
- `Runtime.drain` is the explicit test/shutdown boundary for currently active
  finite daemon work.
- The current/proposed metric pair shows manual daemon bookkeeping is six
  lines; the promoted Eta shape is two lines. The stronger reason is lifecycle:
  callers do not need to own an Eio daemon handle, an atomic completion flag, or
  a polling loop.
- The runnable example proves a daemon can start, remain incomplete before
  drain, and complete after an external release plus `Runtime.drain`.
- No deletion is justified. `with_background` remains the application shape for
  body-owned background children; `daemon` remains an advanced runtime/module
  infrastructure shape.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/daemon_drain.exe
```

Observed API-DX output:

```text
daemon_drain,current,lines=6,effect_bind=0,let_star=0,let_at=0,from_result=0
daemon_drain,proposed,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
daemon-drain:started=true before=false after=true
```

## Bucket 35 - Manual resource refresh

Accepted example/documentation/test changes:

- Added `examples/manual_resource_refresh.ml`.
- Added the manual-resource example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a manual_resource current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to distinguish caller-driven cached refresh from runtime-owned scheduled
  refresh.

No new resource API was accepted in this bucket.

Findings:

- `Resource.manual` and `Resource.refresh` are the right public shape when a
  cached value should be refreshed by an explicit user/admin/operator action
  instead of a runtime-owned schedule.
- The current/proposed metric pair shows a hand-rolled mutable cache/get/refresh
  protocol is twelve lines with four explicit `Effect.bind` calls; the promoted
  Resource shape is four lines, two `let*`, and zero explicit bind calls.
- The runnable example proves a successful caller-driven refresh publishes the
  new value, a failed refresh returns through the caller's typed channel, and
  the last good value remains available. Manual resources do not record
  `Resource.failures`; that diagnostic list belongs to `Resource.auto`.
- No deletion is justified. `Resource.auto` remains the scheduled runtime-owned
  lifecycle. `Resource.manual`/`refresh` remain the caller-owned lifecycle.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/manual_resource_refresh.exe
```

Observed API-DX output:

```text
manual_resource,current,lines=12,effect_bind=4,let_star=0,let_at=0,from_result=0
manual_resource,proposed,lines=4,effect_bind=0,let_star=2,let_at=0,from_result=0
```

Observed example output:

```text
manual-resource:initial=v1:primary refreshed=v2:secondary after-failure=v2:secondary failure=reload-failed:operator rejected reload recorded=0
```

## Bucket 36 - Span linking and current span

Accepted example/documentation/test changes:

- Added `examples/span_linking.ml`.
- Added the span-linking example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a span_link current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to include runtime span inspection and tracer-native links as promoted
  observability evidence.

No new observability API was accepted in this bucket.

Findings:

- `Effect.current_span` is the right public shape when a producer needs to hand
  off the active runtime span identity.
- `Effect.link_span` is the right public shape when a consumer should record a
  causal relationship to another span. Encoding the relationship as
  `linked.trace_id` / `linked.span_id` string attributes is shorter than a custom
  protocol, but it is not tracer-native metadata.
- `Effect.named_kind` remains useful for producer/consumer/client/server span
  classification; a plain name string cannot carry that semantic role.
- The current/proposed metric pair shows attribute-based linking is five lines;
  the promoted link shape is two lines. The stronger reason is semantic:
  exporters can interpret a span link structurally.
- The runnable example proves `current_span` returns producer and consumer span
  identities, the consumer span has kind `Consumer`, the producer span has kind
  `Producer`, and the consumer span records one link to the producer.
- No deletion is justified. `annotate_all` remains correct for ordinary string
  attributes; `link_span` is for span relationships.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/span_linking.exe
```

Observed API-DX output:

```text
span_link,current,lines=5,effect_bind=0,let_star=0,let_at=0,from_result=0
span_link,proposed,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
span-linking:producer=0000000000000001 consumer=0000000000000002 links=1 spans=2
```

## Bucket 37 - Static blueprint name inspection

Accepted example/documentation/test changes:

- Added `examples/blueprint_names.ml`.
- Added the blueprint-name example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a `blueprint_names` current/proposed
  pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to classify `Effect.name` and `Effect.collect_names` as diagnostic/preflight
  surface, not primary workflow style.

No new core API was accepted in this bucket.

Findings:

- `Effect.name` and `Effect.collect_names` are the right public shape when
  tooling, tests, or docs need to inspect statically present names from the
  existing effect description before runtime interpretation.
- A manual registry can track arbitrary expected names, including names that
  appear only after dynamic continuations run, but it is parallel metadata that
  can drift away from the actual blueprint.
- `collect_names` is intentionally not a complete runtime inventory. It does
  not force `bind`, `catch`, `for_each_par`, supervisor bodies, or other
  continuation-producing nodes just to inspect names.
- The runnable example proves the useful boundary: before interpretation the
  program reports `request.handle` and the statically present `config.load`,
  while the `user.load` name created after parsing remains absent until runtime.
- No deletion is justified. The functions are not first-contact workflow
  combinators, but they are useful diagnostic/preflight helpers.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/blueprint_names.exe
```

Observed API-DX output:

```text
blueprint_names,current,lines=4,effect_bind=0,let_star=0,let_at=0,from_result=0
blueprint_names,proposed,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
blueprint-names:name=request.handle static=request.handle,config.load result=primary:user:42
```

## Bucket 38 - Function source-location spans

Accepted example/documentation/test changes:

- Added `examples/source_locations.ml`.
- Added the source-location example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a `source_location` current/proposed
  pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to promote `Effect.fn __POS__ __FUNCTION__` for ordinary function-name spans
  and to keep `Effect.here_attr` as the lower-level wrapper primitive.

No new observability API was accepted in this bucket.

Findings:

- `Effect.fn` is the right public shape when an application function should
  create a named span with compiler-provided source location and ordinary span
  attributes.
- The manual shape has to format a `loc` string, choose a name separately, and
  compose `Effect.named`, `Effect.annotate`, and `Effect.annotate_all`.
  `Effect.fn` keeps those concerns in one wrapper.
- The current/proposed metric pair shows the manual location wrapper is four
  lines; the promoted `fn` shape is one line. The stronger reason is semantic:
  callers pass `__POS__` and `__FUNCTION__` instead of synthesizing a source
  location string.
- `Effect.here_attr` remains useful when a wrapper needs to pass `__POS__`
  through unchanged without choosing a new span name. It is not the preferred
  shape for ordinary function spans.
- The runnable example proves the emitted span name is the compiler-provided
  function name, the span has kind `Client`, the span has caller attrs, and the
  `loc` attr points at `examples/source_locations.ml`.
- No deletion is justified. Manual `named`/`annotate` remains correct for
  custom names and attributes; `fn` is the preferred source-location wrapper.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/source_locations.exe
```

Observed API-DX output:

```text
source_location,current,lines=4,effect_bind=0,let_star=0,let_at=0,from_result=0
source_location,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
source-locations:name=Dune__exe__Source_locations.load_user loc=examples/source_locations.ml:26:4-11 attrs=3 result=USER:42
```

## Bucket 39 - Typed error rendering for observability

Accepted example/documentation/test changes:

- Added `examples/error_rendering.ml`.
- Added the error-rendering example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with an `error_rendering` current/proposed
  pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to promote `Effect.with_error_renderer` and the `?error_renderer` span
  arguments as observability rendering policy for typed failures.

No new observability API was accepted in this bucket.

Findings:

- `Effect.with_error_renderer` is the right public shape when a subtree,
  resource, or finalizer path needs meaningful rendered diagnostics while
  preserving the typed error channel.
- The `?error_renderer` arguments on `named`, `named_kind`, and `fn` remain the
  tighter shape when exactly one span owns the renderer.
- The current/default shape is shorter but produces the opaque
  `<typed failure>` diagnostic. The promoted shape is one line longer and keeps
  the runtime observability output useful without converting domain errors to
  exceptions or strings at the source.
- The runnable example proves a typed failure is still returned as
  `` `Declined "card" ``, while the span status and exception event render
  `declined:card`. It also proves a typed finalizer failure is rendered as
  `ledger-close:payments` in the finalizer cause and as
  `finalizer: ledger-close:payments` in the span status.
- No deletion is justified. Raw typed failure values remain the program
  contract; renderers are scoped diagnostic policy.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/error_rendering.exe
```

Observed API-DX output:

```text
error_rendering,current,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
error_rendering,proposed,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
error-rendering:typed=card status=declined:card finalizer=ledger-close:payments ledger_status=finalizer: ledger-close:payments spans=2
```

## Bucket 40 - One-shot cleanup with `Effect.finally`

Accepted example/documentation/test changes:

- Added `examples/finally_cleanup.ml`.
- Added the finally-cleanup example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a `finally_cleanup` current/proposed
  pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to promote `Effect.finally` for one-shot cleanup around an existing effect.

No new lifecycle API was accepted in this bucket.

Findings:

- `Effect.finally` is the right public shape when cleanup must run after an
  existing effect settles and the cleanup does not depend on a newly acquired
  resource value.
- The hand-written current shape handles success and typed failure by combining
  `catch` and explicit bind, but it does not express cleanup after defects or
  cancellation and it does not own Eta's finalizer/suppressed-cause reporting.
- The current/proposed metric pair shows the manual wrapper is five lines with
  two explicit `Effect.bind` calls; the promoted `finally` shape is one line
  with zero explicit bind calls.
- The runnable example proves cleanup runs after success, after a typed failure,
  and after cancellation by `race`, and that a cleanup typed failure after a
  body typed failure is reported as a suppressed finalizer cause.
- No deletion is justified. `with_resource` remains the body-bounded resource
  bracket when cleanup depends on acquisition; `acquire_release` and `scoped`
  remain the wider-lifetime resource forms.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/finally_cleanup.exe
```

Observed API-DX output:

```text
finally_cleanup,current,lines=5,effect_bind=2,let_star=0,let_at=0,from_result=0
finally_cleanup,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
finally-cleanup:success=ok failure=body-failed cleanup=suppressed cancel=fast marks=success-cleanup,failure-cleanup,cancel-cleanup
```

## Bucket 41 - Typed timeout policy with `Effect.timeout_as`

Accepted example/documentation/test changes:

- Added `examples/timeout_policy.ml`.
- Added the timeout-policy example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a `timeout_policy` current/proposed
  pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to promote `Effect.timeout_as` for domain-typed timeout policies.

No new timeout API was accepted in this bucket.

Findings:

- `Effect.timeout_as` is the right public shape when timeout policy should map
  into the caller's existing typed error row.
- The current manual shape can be short and bind-free using `Effect.race` plus a
  delayed typed failure, so this bucket is not primarily about line count or
  bind removal.
- The semantic win is that `timeout_as` owns losing-branch cancellation, cleanup
  waiting, finalizer/suppressed-cause behavior, and preservation of body
  failures that surface during timeout cancellation.
- The runnable example proves a fast body succeeds, a slow body maps to
  `` `Request_timeout``, and a body domain failure remains
  `` `Invalid_id "empty"`` rather than being collapsed to a timeout.
- No deletion is justified. `Effect.timeout` remains the shorter spelling when
  raw `` `Timeout`` is the desired typed error row member; `Effect.race` remains
  the right primitive for ordinary first-completer concurrency.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/timeout_policy.exe
```

Observed API-DX output:

```text
timeout_policy,current,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
timeout_policy,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
timeout-policy:fast=cache-hit timeout=request-timeout failure=invalid-id:empty
```

## Bucket 42 - Critical cancellation deferral with `Effect.uninterruptible`

Accepted example/documentation/test changes:

- Added `examples/uninterruptible_commit.ml`.
- Added the uninterruptible-commit example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with an `uninterruptible_commit`
  current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to position `Effect.uninterruptible` as interruption-control for small
  critical effects.

No new interruption API was accepted in this bucket.

Findings:

- `Effect.uninterruptible` is the right public marker when a small critical
  effect must finish once it has started, even if a parent race or scope
  cancellation selects another branch.
- The current and proposed snippets are both one line and both avoid explicit
  bind, so the evidence is entirely semantic: the proposed branch carries
  backend cancellation protection and the current one does not.
- The helper does not catch defects and does not convert interruption into a
  typed failure. The docs should continue to describe it as a narrow critical
  section tool, not a blanket around long-running work.
- The runnable example proves a fast branch wins a race while the protected
  branch still commits before the race result is returned.
- No deletion is justified. `Effect.race` remains the ordinary first-completer
  concurrency primitive; `uninterruptible` is the explicit cancellation mask for
  the rare branch that must not be torn down mid-commit.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/uninterruptible_commit.exe
```

Observed API-DX output:

```text
uninterruptible_commit,current,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
uninterruptible_commit,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
uninterruptible-commit:winner=fast committed=true
```

## Bucket 43 - Scheduled unit recurrence with `Effect.repeat`

Accepted example/documentation/test changes:

- Added `examples/repeat_heartbeat.ml`.
- Added the repeat-heartbeat example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a `repeat_heartbeat` current/proposed
  pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to promote `Effect.repeat` for scheduled unit-work recurrence.

No new recurrence API was accepted in this bucket.

Findings:

- `Effect.repeat` is the right public shape when application code wants a
  scheduled unit effect such as a heartbeat, refresh, or maintenance tick.
- The manual current shape drives `Schedule.start` / `Schedule.next` directly,
  sleeps between iterations, and uses explicit bind to continue the loop. That
  is useful interpreter code, but too low-level for ordinary application
  recurrence.
- The proposed shape is one line, exposes no bind, and leaves schedule driving,
  sleeps, cancellation, and iteration failure behavior inside Eta.
- The runnable example proves `Schedule.recurs 3` runs the body once initially
  plus three repeats.
- No deletion is justified. `Schedule.start` and `Schedule.next` remain
  interpreter/advanced APIs; `Effect.repeat` is the preferred application
  helper for unit recurrence.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/repeat_heartbeat.exe
```

Observed API-DX output:

```text
repeat_heartbeat,current,lines=8,effect_bind=1,let_star=0,let_at=0,from_result=0
repeat_heartbeat,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
repeat-heartbeat:ticks=4 policy=recurs:3
```

## Bucket 44 - Success-side observation with `Effect.tap`

Accepted example/documentation/test changes:

- Added `examples/tap_success.ml`.
- Added the tap-success example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a `tap_success` current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to promote `Effect.tap` for success-side observers that preserve the original
  value.

No new observation API was accepted in this bucket.

Findings:

- `Effect.tap` is the right public shape when an effectful observer should run
  after success and the original success value should continue unchanged.
- The current shape is the common primitive pattern:
  `bind value -> observer value |> map (fun () -> value)`. It exposes bind and
  repeats the preservation boilerplate at every observation site.
- The proposed shape is one line with zero explicit bind calls and keeps the
  observer result intentionally ignored.
- The runnable example proves the observer records `loaded:42` while the
  workflow continues with the original user name `Ada`.
- No deletion is justified. `Effect.bind` remains the primitive, and `let*`
  remains the right application spelling when subsequent work depends on the
  observer's result.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/tap_success.exe
```

Observed API-DX output:

```text
tap_success,current,lines=3,effect_bind=1,let_star=0,let_at=0,from_result=0
tap_success,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
tap-success:user=Ada audit=loaded:42
```

## Bucket 45 - Fail-fast homogeneous collection with `Effect.all`

Accepted example/documentation/test changes:

- Added `examples/all_health_checks.ml`.
- Added the all-health-checks example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with an `all_collect` current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to promote `Effect.all` for dynamic homogeneous fail-fast collection.

No new concurrency API was accepted in this bucket.

Findings:

- `Effect.all` is the right public shape when a workflow has a dynamic
  homogeneous list of independent effects and wants fail-fast collection.
- The current recursive shape is eight lines and exposes a primitive
  `Effect.bind` plus `Effect.map` loop just to preserve input order and collect
  values.
- The proposed shape is one line, exposes no bind, and leaves concurrency,
  cancellation, result ordering, and fail-fast behavior inside Eta.
- The runnable example proves the all-success path preserves input order
  (`db,cache,queue`) and the failing path returns the typed child failure
  `` `Check_failed "search"``.
- No deletion is justified. `and*` remains the preferred fixed-arity syntax,
  `for_each_par_bounded` remains the bounded mapped-workload helper, and
  `all_settled` remains the helper when every child outcome is the value being
  collected.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/all_health_checks.exe
```

Observed API-DX output:

```text
all_collect,current,lines=8,effect_bind=1,let_star=0,let_at=0,from_result=0
all_collect,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
all-health:ok=db,cache,queue failure=check-failed:search
```

## Bucket 46 - Typed failure recovery with `Effect.catch`

Accepted example/documentation/test changes:

- Added `examples/catch_recovery.ml`.
- Added the catch-recovery example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a `catch_recovery` current/proposed
  pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to promote `Effect.catch` for typed failure recovery inside an Eta blueprint.

No new typed recovery API was accepted in this bucket. Bucket 62 later adds
`Effect.recover` for pure recovery; `Effect.catch` remains the effectful
recovery shape promoted here.

Findings:

- `Effect.catch` is the right public shape when expected domain failures should
  recover inside the effect blueprint.
- The current shape encodes expected failures as successful `result` values and
  branches with `Effect.bind`. That moves the error out of Eta's typed failure
  channel and makes recovery look like success-value plumbing.
- The proposed shape keeps the expected failure in the typed channel and
  recovers with `Effect.catch`, with zero explicit bind calls.
- The runnable example proves a typed `` `Cache_miss`` recovers to `fallback`,
  while an unchecked `Failure "boom"` remains a `Cause.Die` and is not caught by
  typed recovery.
- No deletion is justified. `Effect.bind` remains the primitive sequencing
  operation; `Effect.catch` is the preferred user-facing typed recovery helper.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/catch_recovery.exe
```

Observed API-DX output:

```text
catch_recovery,current,lines=4,effect_bind=1,let_star=0,let_at=0,from_result=0
catch_recovery,proposed,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
catch-recovery:recovered=fallback defect=defect-not-caught
```

## Bucket 47 - Success-value projection with `Eta.Syntax.(let+)`

Accepted example/documentation/test changes:

- Added `examples/map_projection.ml`.
- Added the map-projection example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a `success_map` current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to promote `Eta.Syntax.(let+)` for pure success-value projection.

No new mapping API was accepted in this bucket.

Findings:

- `Eta.Syntax.(let+)` is the right public shape when a continuation is pure and
  only projects a successful value.
- The current shape uses `Effect.bind` plus `Effect.pure`, which makes pure
  projection look like dependent effect sequencing.
- The proposed shape exposes no explicit bind and makes the pure continuation
  visible in the syntax.
- The runnable example proves a loaded user is projected to the label
  `user:42:Ada`.
- No deletion is justified. `Effect.map` remains the primitive, and `let*`
  remains the preferred spelling when the continuation returns another effect.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/map_projection.exe
```

Observed API-DX output:

```text
success_map,current,lines=3,effect_bind=1,let_star=0,let_at=0,from_result=0
success_map,proposed,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
map-projection:user:42:Ada
```

## Bucket 48 - Pure validation lifting with `Effect.from_result`

Accepted example/documentation/test changes:

- Added `examples/validation_boundary.ml`.
- Added the validation-boundary example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a `validation_boundary` current/proposed
  pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to keep `Effect.from_result` visible for already-computed validation results.

No new result-lifting API was accepted in this bucket.

Findings:

- `Effect.from_result` is the right public shape when validation or parsing has
  already produced an OCaml `result`.
- The current `Effect.sync_result (fun () -> parse raw)` shape is also one line,
  but it misclassifies pure validation as a synchronous leaf. That distinction
  matters because synchronous leaves run under Eta's defect/cancellation
  boundary, while an already-computed `result` only needs lifting.
- The proposed shape has no explicit bind and records one `Effect.from_result`
  use in the metric gate.
- The runnable example proves a valid id becomes `user:42` and invalid input
  remains a typed `` `Invalid_id "empty"`` failure.
- No deletion is justified. `Effect.sync_result` remains the right helper when
  the synchronous leaf itself computes an expected `result` failure.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/validation_boundary.exe
```

Observed API-DX output:

```text
validation_boundary,current,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
validation_boundary,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=1
```

Observed example output:

```text
validation-boundary:ok=user:42 failure=invalid-id:empty
```

## Bucket 49 - Synchronous defect capture with `Effect.sync`

Accepted example/documentation/test changes:

- Added `examples/sync_defect_boundary.ml`.
- Added the sync-defect example to the Dune `@examples` alias.
- Added it to the promoted-surface scanner.
- Extended the API-DX metric gate with a `sync_defect` current/proposed pair.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface audit
  to keep `Effect.sync` visible for synchronous leaves whose exceptions should
  remain defects.

No new synchronous leaf API was accepted in this bucket.

Findings:

- `Effect.sync` is the right public shape when a synchronous leaf may raise an
  unexpected exception that should be reported as an Eta defect.
- The current shape catches `Failure` and converts it to a typed `Error`,
  which incorrectly turns a bug/defect into a domain error.
- The proposed shape is a direct `Effect.sync` leaf with no explicit bind and no
  ad hoc `try` / `Error` wrapper.
- The runnable example proves a successful leaf returns `config:ok` and a
  raised exception is reported as `Cause.Die`.
- No deletion is justified. `Effect.sync_result` remains the right helper when
  the synchronous leaf intentionally returns expected typed failures as
  `result`.

Verification:

```sh
dune runtest test/api_dx --force
nix develop -c dune exec examples/sync_defect_boundary.exe
```

Observed API-DX output:

```text
sync_defect,current,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
sync_defect,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
sync-defect:ok=config:ok defect=die
```

## Bucket 50 - Supervisor nursery metric proof

Accepted test/documentation changes:

- Added a typed `supervisor_current` / `supervisor_proposed` pair to
  `test/api_dx/api_dx_examples.ml`.
- Added a `supervisor` current/proposed metric pair to the API-DX snippet gate.
- Extended `docs/api-dx.md` to list the supervisor nursery as a preferred shape
  specifically when code needs child handles that cannot escape their scope.
- Added `examples/supervisor_scope.exe` to the public API-DX verification list.

No new supervisor API was accepted in this bucket.

Findings:

- The proposed supervisor shape is not shorter than manual background
  bookkeeping. That is expected: the point of `Supervisor.scoped { run = ... }`
  is the rank-2 nursery token that keeps child handles from escaping.
- The user-facing spelling still avoids explicit `Effect.bind`; sequencing
  inside the nursery is `Supervisor.Scope.(let*)`, not the primitive
  `Supervisor.Scope.bind`.
- `Effect.with_background` remains the preferred body-owned background helper
  when no child handle is needed. `Supervisor.scoped` remains the handle-owning
  nursery shape.
- No deletion is justified. The low-level `Effect.supervisor_*` builders remain
  implementation bridges behind `Eta.Supervisor`.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
```

Observed API-DX output:

```text
supervisor,current,lines=6,effect_bind=0,let_star=0,let_at=0,from_result=0
supervisor,proposed,lines=8,effect_bind=0,let_star=3,let_at=0,from_result=0
```

## Bucket 51 - Resource refresh diagnostics with `Resource.failures`

Accepted test/documentation changes:

- Added a typed `resource_failures_current` / `resource_failures_proposed` pair
  to `test/api_dx/api_dx_examples.ml`.
- Added a `resource_failures` current/proposed metric pair to the API-DX
  snippet gate.
- Updated `docs/api-dx.md` to list `Eta.Resource.failures` as the preferred
  shape for resource-owned refresh diagnostics.

No new resource API was accepted in this bucket.

Findings:

- `Resource.failures` is the right public shape when a caller needs the
  resource-owned diagnostic history for scheduled refresh failures.
- A caller-owned `ref []` populated from `~on_error` is a side channel. It can
  observe typed refresh failures immediately, but it does not own the resource's
  cause ledger and should not be the preferred shape for later diagnostics.
- The proposed shape is shorter, keeps zero explicit `Effect.bind`, and records
  `Resource.failures` directly in the metric gate.
- No deletion is justified. `~on_error` remains useful for immediate
  side-effects such as logging or incrementing counters; `Resource.failures`
  remains the inspection API for the resource-owned history.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
```

Observed API-DX output:

```text
resource_failures,current,lines=6,effect_bind=0,let_star=2,let_at=0,from_result=0
resource_failures,proposed,lines=4,effect_bind=0,let_star=2,let_at=0,from_result=0
```

## Bucket 52 - Deterministic random collection helpers

Accepted test/documentation changes:

- Added a typed `random_collections_current` / `random_collections_proposed`
  pair to `test/api_dx/api_dx_examples.ml`.
- Added a `random_collections` current/proposed metric pair to the API-DX
  snippet gate.
- Updated `docs/api-dx.md` to list scalar and collection random helpers as
  preferred application API.

No new random API was accepted in this bucket.

Findings:

- `Random.shuffle`, `Random.weighted_choice`, and `Random.sample` are the right
  public shape when application code needs deterministic collection draws from
  the same portable random token used by runtime schedules.
- The manual shape has to sort by generated float keys, choose an index from a
  raw float, accumulate positive weights, and route edge cases manually.
- The proposed shape is four lines, keeps zero explicit `Effect.bind`, and
  records all three collection helpers directly in the metric gate.
- No deletion is justified. `Capabilities.random_float` remains the primitive
  runtime token operation; `Random.*` remains the application helper surface.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
```

Observed API-DX output:

```text
random_collections,current,lines=23,effect_bind=0,let_star=0,let_at=0,from_result=0
random_collections,proposed,lines=4,effect_bind=0,let_star=0,let_at=0,from_result=0
```

## Bucket 53 - Log-level rendering and OTLP boundaries

Accepted test/documentation changes:

- Added a typed `log_level_boundary_current` / `log_level_boundary_proposed`
  pair to `test/api_dx/api_dx_examples.ml`.
- Added a `log_level_boundary` current/proposed metric pair to the API-DX
  snippet gate.
- Updated `docs/api-dx.md` and `examples/README.md` to name log-level
  rendering and OTLP severity conversion as preferred boundary helpers.

No new log-level API was accepted in this bucket.

Findings:

- `Log_level.to_string`, `Log_level.to_otel_severity`,
  `Log_level.of_otel_severity`, and `Log_level.pp` are the right public shape
  when log levels cross string or OTLP integer boundaries.
- The manual shape has to maintain a string rendering convention, an OTLP
  severity-number table, and a reverse integer ladder.
- The proposed shape is five lines, keeps zero explicit `Effect.bind`, and
  records all four boundary helpers directly in the metric gate.
- No deletion is justified. Raw strings and OTLP severity numbers remain
  external formats; `Log_level.t` remains the application policy
  representation.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
```

Observed API-DX output:

```text
log_level_boundary,current,lines=16,effect_bind=0,let_star=0,let_at=0,from_result=0
log_level_boundary,proposed,lines=5,effect_bind=0,let_star=0,let_at=0,from_result=0
```

## Bucket 54 - Trace context outbound injection

Accepted test/documentation changes:

- Added a typed `trace_context_injection_current` /
  `trace_context_injection_proposed` pair to `test/api_dx/api_dx_examples.ml`.
- Added a `trace_context_injection` current/proposed metric pair to the API-DX
  snippet gate.
- Updated `docs/api-dx.md` to name `Effect.current_context` plus
  `Trace_context.inject` as the preferred outbound W3C propagation shape.

No new trace-context API was accepted in this bucket.

Findings:

- `Effect.current_context` plus `Trace_context.inject` is the right public
  shape when an outbound boundary should propagate the runtime's current W3C
  context.
- The manual shape has to format `traceparent`, serialize `tracestate`, and
  serialize `baggage` by hand.
- The proposed shape is five lines, keeps zero explicit `Effect.bind`, and uses
  one `let*` because reading runtime context is effectful.
- No deletion is justified. `Effect.with_external_parent` remains the narrow
  compatibility shape for boundaries that only have trace/span IDs;
  `Trace_context.inject` remains the full W3C outbound helper.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
```

Observed API-DX output:

```text
trace_context_injection,current,lines=13,effect_bind=0,let_star=0,let_at=0,from_result=0
trace_context_injection,proposed,lines=5,effect_bind=0,let_star=1,let_at=0,from_result=0
```

## Bucket 55 - Non-blocking bounded-channel probes

Accepted test/documentation/example changes:

- Added a typed `channel_probe_current` / `channel_probe_proposed` pair to
  `test/api_dx/api_dx_examples.ml`.
- Added a `channel_probe` current/proposed metric pair to the API-DX snippet
  gate.
- Added `examples/channel_probe.ml` as executable evidence for `try_send`,
  `try_recv`, counters, and typed close results.
- Updated `docs/api-dx.md` and `examples/README.md` to name non-blocking
  bounded-channel probes as a preferred API shape.

No new channel API was accepted in this bucket.

Findings:

- `Channel.try_send` and `Channel.try_recv` are the right public shape when a
  caller needs a non-blocking bounded-channel probe.
- The manual shape checks `Channel.stats`, carries the channel capacity in
  application code, and then still needs blocking `send` / `recv` plus typed
  recovery because the real channel state can change after the snapshot.
- The proposed shape is four lines, keeps zero explicit `Effect.bind`, and
  preserves full `send_result` / `recv_result` values directly.
- No deletion is justified. `Channel.send` and `Channel.recv` remain the
  preferred waiting handoff operations; `try_send` and `try_recv` are for the
  non-blocking branch.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune exec examples/channel_probe.exe
```

Observed API-DX output:

```text
channel_probe,current,lines=19,effect_bind=0,let_star=1,let_at=0,from_result=0
channel_probe,proposed,lines=4,effect_bind=0,let_star=1,let_at=0,from_result=0
```

Observed example output:

```text
channel-probe:empty=empty sent=sent full=full first=item:alpha depth=0 counters=1/1 closed_send=closed:done closed_recv=closed:done
```

## Bucket 56 - Non-blocking scoped pubsub polls

Accepted test/documentation/example changes:

- Added a typed `pubsub_poll_current` / `pubsub_poll_proposed` pair to
  `test/api_dx/api_dx_examples.ml`.
- Added a `pubsub_poll` current/proposed metric pair to the API-DX snippet
  gate.
- Added `examples/pubsub_poll.ml` as executable evidence for `try_recv`
  returning empty, item, and typed close results inside a scoped subscription.
- Updated `docs/api-dx.md` and `examples/README.md` to name non-blocking
  scoped subscription polling as a preferred API shape.

No new pubsub API was accepted in this bucket.

Findings:

- `Pubsub.try_recv` is the right public shape when a scoped subscriber needs a
  non-blocking poll.
- The manual shape checks hub-level `Pubsub.stats` and then still needs
  blocking `Pubsub.recv` plus typed recovery. Hub stats cannot tell whether a
  particular subscription cursor has a message, and a snapshot can be stale
  before the blocking receive runs.
- The proposed shape is one line, keeps zero explicit `Effect.bind`, and
  preserves full `recv_result` values directly.
- No deletion is justified. `Pubsub.recv` remains the preferred waiting
  subscription read; `try_recv` is for the non-blocking branch.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune exec examples/pubsub_poll.exe
```

Observed API-DX output:

```text
pubsub_poll,current,lines=6,effect_bind=0,let_star=0,let_at=0,from_result=0
pubsub_poll,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
pubsub-poll:empty=empty published=1 first=item:created closed=closed:broker subscribers=1 received=1
```

## Bucket 57 - Non-blocking unbounded-queue probes

Accepted test/documentation/example changes:

- Added a typed `queue_probe_current` / `queue_probe_proposed` pair to
  `test/api_dx/api_dx_examples.ml`.
- Added a `queue_probe` current/proposed metric pair to the API-DX snippet
  gate.
- Added `examples/queue_probe.ml` as executable evidence for `try_send`,
  `try_recv`, counters, and typed close results.
- Updated `docs/api-dx.md` and `examples/README.md` to name non-blocking
  unbounded-queue probes as a preferred API shape.

No new queue API was accepted in this bucket.

Findings:

- `Queue.try_send` and `Queue.try_recv` are the right public shape when a
  caller needs a non-blocking unbounded-queue probe.
- The manual shape checks `Queue.stats`, then still needs blocking
  `Queue.send` / `Queue.recv` plus typed recovery. The stats snapshot only
  exposes `closed : bool`, so it cannot preserve a typed close reason.
- The proposed shape is four lines, keeps zero explicit `Effect.bind`, and
  preserves full `send_result` / `recv_result` values directly.
- No deletion is justified. `Queue.send` and `Queue.recv` remain the preferred
  waiting handoff operations; `try_send` and `try_recv` are for the
  non-blocking branch.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune exec examples/queue_probe.exe
```

Observed API-DX output:

```text
queue_probe,current,lines=19,effect_bind=0,let_star=1,let_at=0,from_result=0
queue_probe,proposed,lines=4,effect_bind=0,let_star=1,let_at=0,from_result=0
```

Observed example output:

```text
queue-probe:empty=empty sent=sent first=item:alpha depth=0 counters=1/1 closed_send=closed:done closed_recv=closed:done
```

## Bucket 58 - Lexical semaphore permits

Accepted test/documentation/example changes:

- Added a typed `semaphore_permit_current` / `semaphore_permit_proposed` pair
  to `test/api_dx/api_dx_examples.ml`.
- Added a `semaphore_permit` current/proposed metric pair to the API-DX
  snippet gate.
- Added `examples/semaphore_permits.ml` as executable evidence for
  `with_permits` releasing permits on success and typed failure.
- Updated `docs/api-dx.md` and `examples/README.md` to name lexical semaphore
  permits as a preferred API shape.

No new semaphore API was accepted in this bucket.

Findings:

- `Semaphore.with_permits` is the right public shape when a caller needs
  lexical permit ownership without an abort signal.
- The manual shape has to acquire, sequence into the body with explicit
  `Effect.bind`, and remember a release finalizer.
- The proposed shape is one line, keeps zero explicit `Effect.bind`, and keeps
  permit cleanup owned by Eta.
- No deletion is justified. Raw `try_acquire`, `acquire`, and `release` remain
  low-level capabilities for custom protocols, tests, and internals such as
  pools.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune exec examples/semaphore_permits.exe
```

Observed API-DX output:

```text
semaphore_permit,current,lines=5,effect_bind=1,let_star=0,let_at=0,from_result=0
semaphore_permit,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed example output:

```text
semaphore-permits:first=alpha:available=0 failed=failed:boom available=1 waiting=0
```

## Bucket 59 - Effectful handoff close

Accepted additive API changes:

- `Eta.Channel.close_effect`
- `Eta.Channel.close_with_error_effect`
- `Eta.Queue.close_effect`
- `Eta.Queue.close_with_error_effect`
- `Eta.Pubsub.close_effect`
- `Eta.Pubsub.close_with_error_effect`

Accepted test/documentation/example changes:

- Added a typed `handoff_close_current` / `handoff_close_proposed` pair to
  `test/api_dx/api_dx_examples.ml`.
- Added a `handoff_close` current/proposed metric pair to the API-DX snippet
  gate.
- Updated the channel, queue, channel-probe, queue-probe, pubsub-subscription,
  and pubsub-poll examples to use `*_close_with_error_effect` helpers instead
  of raw `Effect.sync` wrappers.
- Added runtime-common coverage for clean and typed effectful close helpers.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface notes
  to describe workflow close helpers as the preferred Eta shape inside
  blueprints.

Findings:

- Close is a workflow action when it is sequenced after sends, receives, or
  publishes inside an Eta blueprint.
- The immediate `close` / `close_with_error` functions remain useful for host
  callbacks and low-level internals, so no deletion is justified in this
  bucket.
- The proposed shape keeps zero explicit `Effect.bind` and removes raw
  `Effect.sync` lifting at the close point.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune runtest test/runtime_eio --force
nix develop -c dune exec examples/bounded_channel.exe
nix develop -c dune exec examples/channel_probe.exe
nix develop -c dune exec examples/unbounded_queue.exe
nix develop -c dune exec examples/queue_probe.exe
nix develop -c dune exec examples/pubsub_subscription.exe
nix develop -c dune exec examples/pubsub_poll.exe
nix develop -c dune build @examples
nix develop -c dune runtest examples --force
nix develop -c dune build @install
nix develop -c dune runtest --force
```

Observed API-DX output:

```text
handoff_close,current,lines=4,effect_bind=0,let_star=2,let_at=0,from_result=0
handoff_close,proposed,lines=4,effect_bind=0,let_star=2,let_at=0,from_result=0
```

Observed changed-example outputs:

```text
channel:first=first second=second closed=closed:done blocked=1/1 sent=2 received=2
channel-probe:empty=empty sent=sent full=full first=item:alpha depth=0 counters=1/1 closed_send=closed:done closed_recv=closed:done
queue:first=alpha second=beta third=gamma closed=closed:done depth=3 waiting=0 sent=3 received=3
queue-probe:empty=empty sent=sent first=item:alpha depth=0 counters=1/1 closed_send=closed:done closed_recv=closed:done
pubsub:published=1 first=created closed=closed:broker subscribers=1 received=1
pubsub-poll:empty=empty published=1 first=item:created closed=closed:broker subscribers=1 received=1
```

## Bucket 60 - Direct handoff snapshots

No new API was accepted in this bucket.

Accepted test/documentation/example changes:

- Added a typed `handoff_snapshot_current` / `handoff_snapshot_proposed` pair
  to `test/api_dx/api_dx_examples.ml`.
- Added a `handoff_snapshot` current/proposed metric pair to the API-DX
  snippet gate.
- Updated channel, queue, pubsub, admission-control, and semaphore-permit
  examples to read immediate snapshots directly inside workflow continuations
  and lift the final combined value with `Effect.pure`.
- Updated `docs/api-dx.md` and the effect-surface notes to record that
  `stats_effect` wrappers are not justified by the current evidence.

Findings:

- `Channel.stats`, `Queue.stats`, `Pubsub.stats`, `Semaphore.available`, and
  `Semaphore.waiting` are synchronous snapshots, not Eta-owned lifecycle
  actions.
- The current shape wrapped each snapshot in `Effect.sync`, adding several
  sequencing points without improving typed errors, lifecycle ownership, or
  observability.
- The proposed shape keeps zero explicit `Effect.bind`, removes four workflow
  `let*`/`let+` snapshot steps from the snippet, and preserves the existing
  immediate snapshot APIs.
- No deletion or addition is justified. Immediate snapshots stay immediate;
  examples should not manufacture effects for plain reads.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune exec examples/bounded_channel.exe
nix develop -c dune exec examples/unbounded_queue.exe
nix develop -c dune exec examples/pubsub_subscription.exe
nix develop -c dune exec examples/pubsub_poll.exe
nix develop -c dune exec examples/admission_control.exe
nix develop -c dune exec examples/semaphore_permits.exe
```

Observed API-DX output:

```text
handoff_snapshot,current,lines=8,effect_bind=0,let_star=3,let_at=0,from_result=0
handoff_snapshot,proposed,lines=7,effect_bind=0,let_star=0,let_at=0,from_result=0
```

Observed changed-example outputs:

```text
channel:first=first second=second closed=closed:done blocked=1/1 sent=2 received=2
queue:first=alpha second=beta third=gamma closed=closed:done depth=3 waiting=0 sent=3 received=3
pubsub:published=1 first=created closed=closed:broker subscribers=1 received=1
pubsub-poll:empty=empty published=1 first=item:created closed=closed:broker subscribers=1 received=1
admission:accepted:alpha:available=0,busy:beta available=1 waiting=0
semaphore-permits:first=alpha:available=0 failed=failed:boom available=1 waiting=0
```

## Bucket 61 - Synchronous success-side observation

Accepted additive API change:

- `Effect.tap_sync`

Accepted test/documentation/example changes:

- Added `Effect.tap_sync` to `lib/eta/effect.mli` and the core
  implementation.
- Added a typed `tap_sync_observer_current` / `tap_sync_observer_proposed`
  pair to `test/api_dx/api_dx_examples.ml`.
- Extended `examples/tap_success.ml` so the same runnable example shows both a
  synchronous observer with `tap_sync` and an effectful observer with `tap`.
- Added runtime-common coverage for success preservation and observer defects.
- Updated `docs/api-dx.md` and the effect-surface notes to describe
  `tap_sync` as the synchronous-observer companion to `tap`.

Findings:

- `Effect.tap` is still the right API when the observer itself is an Eta
  effect.
- Synchronous success observers previously needed the shape
  `Effect.tap (fun value -> Effect.sync (fun () -> observe value))`, which
  exposes leaf lifting noise at every observation point.
- `Effect.tap_sync` keeps the same success-preserving semantics and the same
  defect behavior as `Effect.sync`: exceptions raised by the observer are
  unchecked defects.
- No deletion is justified. `tap` and `tap_sync` cover different observer
  kinds.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune runtest test/runtime_eio --force
nix develop -c dune runtest test/core_eio --force
nix develop -c dune exec examples/tap_success.exe
nix develop -c dune build @examples
nix develop -c dune runtest examples --force
nix develop -c dune build @install
nix develop -c dune runtest --force
```

Observed API-DX output:

```text
tap_sync_observer,current,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
tap_sync_observer,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

## Bucket 62 - Pure typed failure recovery

Accepted additive API change:

- `Effect.recover`

Accepted test/documentation/example changes:

- Added `Effect.recover` to `lib/eta/effect.mli` and the core
  implementation.
- Added a typed `pure_recovery_current` / `pure_recovery_proposed` pair to
  `test/api_dx/api_dx_examples.ml`.
- Updated promoted examples that recovered typed failures into plain values:
  `quickstart.ml`, `catch_recovery.ml`, `manual_resource_refresh.ml`,
  `bounded_channel.ml`, `unbounded_queue.ml`, `pubsub_subscription.ml`, and
  `semaphore_permits.ml`.
- Updated `Eta_http.Server.Handler.with_default_error_response` to use
  `Effect.recover` for pure error rendering.
- Added runtime-common coverage for typed recovery, unrecovered defects, and
  recovery-handler defects.
- Updated `README.md`, `docs/api-dx.md`, `examples/README.md`, and the
  effect-surface notes to describe `recover` as the pure companion to `catch`.

Findings:

- `Effect.catch` remains the right API when recovery returns another Eta
  effect.
- Pure recovery previously needed
  `Effect.catch (fun err -> Effect.pure (render err))`, exposing a local
  `Effect.pure` wrapper at every recovery point.
- `Effect.recover` preserves `catch` semantics: it recovers typed failures only;
  defects, interruption, and finalizer diagnostics remain unrecovered.
- If the pure recovery function raises, the exception remains an unchecked
  defect.
- No deletion is justified. `catch` and `recover` cover different recovery
  kinds.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune runtest test/runtime_eio --force
nix develop -c dune runtest test/core_eio --force
nix develop -c dune exec examples/catch_recovery.exe
nix develop -c dune exec examples/bounded_channel.exe
nix develop -c dune exec examples/unbounded_queue.exe
nix develop -c dune exec examples/pubsub_subscription.exe
nix develop -c dune exec examples/semaphore_permits.exe
nix develop -c dune exec examples/manual_resource_refresh.exe
nix develop -c dune build @examples
nix develop -c dune runtest examples --force
nix develop -c dune build @install
nix develop -c dune runtest --force
```

Observed API-DX output:

```text
pure_recovery,current,lines=2,effect_bind=0,let_star=0,let_at=0,from_result=0
pure_recovery,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

## Bucket 63 - Backend-neutral cooperative yield

Accepted additive API change:

- `Effect.yield`

Accepted test/documentation/example changes:

- Added `Effect.yield` to `lib/eta/effect.mli` and the core implementation.
- Added a `cooperative_yield_current` / `cooperative_yield_proposed` pair to
  `test/api_dx/api_dx_examples.ml`.
- Updated `examples/background_lifecycle.ml` to use `Effect.yield` for the
  blueprint-level scheduling point.
- Added runtime-common and core-common coverage that `Effect.yield` returns
  normally through the active runtime.
- Updated `docs/api-dx.md`, `examples/README.md`, and the effect-surface notes
  to document cooperative yielding as a runtime-contract surface.

Findings:

- `Effect.sync Eio.Fiber.yield` leaks the Eio backend into Eta workflow
  blueprints.
- `Effect.yield` preserves Eta's runtime-backend boundary by delegating to the
  runtime contract.
- No deletion is justified. Backend-specific yielding remains appropriate
  inside host callbacks and test polling loops where the code is already
  operating at the host-runtime edge.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune runtest test/runtime_eio --force
nix develop -c dune runtest test/core_eio --force
nix develop -c dune exec examples/background_lifecycle.exe
nix develop -c dune build @examples
nix develop -c dune runtest examples --force
nix develop -c dune build @install
nix develop -c dune runtest --force
```

Observed API-DX output:

```text
cooperative_yield,current,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
cooperative_yield,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

## Bucket 64 - Best-effort typed failure suppression

Accepted additive API change:

- `Effect.ignore_errors`

Accepted test/documentation/example changes:

- Added `Effect.ignore_errors` to `lib/eta/effect.mli` and the core
  implementation.
- Added a `best_effort_current` / `best_effort_proposed` pair to
  `test/api_dx/api_dx_examples.ml`.
- Updated the manual resource API-DX proposed snippet to use
  `Effect.ignore_errors` for best-effort caller-driven refresh.
- Updated exact best-effort unit cleanup sites in HTTP, OTEL, and stress tests
  away from raw `Effect.catch (fun _ -> Effect.unit)`.
- Added runtime-common and core-common coverage for successful unit effects,
  suppressed typed failures, and unrecovered defects.
- Updated `docs/api-dx.md` and the effect-surface notes to describe
  `ignore_errors` as the narrow best-effort unit helper.

Findings:

- `Effect.catch` remains the right API when recovery chooses another Eta
  effect from the typed error.
- `Effect.recover` remains the right API when recovery computes a plain success
  value.
- Best-effort unit effects previously needed
  `Effect.catch (fun _ -> Effect.unit)`, exposing a local unit recovery wrapper
  at cleanup/refresh/notification sites.
- `Effect.ignore_errors` is intentionally restricted to unit effects so it does
  not become a general value-discarding combinator. It suppresses typed
  failures only; defects, interruption, and finalizer diagnostics stay visible.
- No deletion is justified. `catch`, `recover`, and `ignore_errors` cover
  distinct recovery shapes.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune runtest test/runtime_eio --force
nix develop -c dune runtest test/core_eio --force
nix develop -c dune build @examples
nix develop -c dune runtest examples --force
nix develop -c dune build @install
nix develop -c dune runtest --force
```

Observed API-DX output:

```text
best_effort,current,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
best_effort,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```

## Bucket 65 - Typed failure materialization

Accepted additive API change:

- `Effect.result`

Accepted test/documentation/example changes:

- Added `Effect.result` to `lib/eta/effect.mli` and the core implementation.
- Added a `typed_failure_result_current` / `typed_failure_result_proposed` pair
  to `test/api_dx/api_dx_examples.ml`.
- Updated `examples/manual_resource_refresh.ml` to materialize
  `Resource.refresh` as `Effect.result` before mapping the typed failure to the
  example's `option` value.
- Added runtime-common and core-common coverage for successful values, typed
  failures, unrecovered defects, and unrecovered finalizer diagnostics.
- Updated `docs/api-dx.md`, `README.md`, and the effect-surface notes to
  distinguish typed recovery from typed failure materialization.

Findings:

- Local prior art supports this shape: Effect v4 names the operation
  `Effect.result` and documents `Effect.either` as the previous name.
- The current Eta shape for materializing the typed failure channel was
  `Effect.map (fun value -> Ok value) |> Effect.recover (fun err -> Error err)`.
  That is correct but exposes two combinators for a single common outcome
  encapsulation operation.
- `Effect.result` keeps the operation inside the Eta blueprint. It is different
  from `Exit.to_result`, which is a partial runtime-boundary adapter over an
  already produced `Exit`.
- No deletion is justified. `catch`, `recover`, `ignore_errors`, and `result`
  cover distinct typed-failure shapes: effectful recovery, pure recovery,
  best-effort unit suppression, and success/failure materialization as data.

Verification:

```sh
nix develop -c dune runtest test/api_dx --force
nix develop -c dune runtest test/runtime_eio --force
nix develop -c dune runtest test/core_eio --force
nix develop -c dune build @examples
nix develop -c dune runtest examples --force
nix develop -c dune build @install
nix develop -c dune runtest --force
```

Observed API-DX output:

```text
typed_failure_result,current,lines=3,effect_bind=0,let_star=0,let_at=0,from_result=0
typed_failure_result,proposed,lines=1,effect_bind=0,let_star=0,let_at=0,from_result=0
```
