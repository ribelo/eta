# Eta substrate capability support

Date: 2026-08-10

Ticket: [`docs/wayfinder/eta-crux-capability-audit/issues/06-eta-substrate-capability-support.md`](../../../docs/wayfinder/eta-crux-capability-audit/issues/06-eta-substrate-capability-support.md)

## Question

Which current Eta capabilities can support the reported and newly discovered Eta Crux candidates?

This report records substrate facts only.
It does not decide adopt, defer, or reject for any candidate.
It does not change the wayfinder tickets, the map, production code, tests, or existing research files.

## Method

The primary sources are repository interfaces, implementations, tests, Dune metadata, and tracked design documents.
The report inspects implementation details only when a public contract depends on them.

| Source | Role |
|---|---|
| `lib/eta/effect.mli` | Public effect surface |
| `lib/eta/runtime.mli`, `lib/eta/runtime_contract.mli`, `lib/eta/spi.mli` | Runtime interpreter and backend contract |
| `lib/eta/duration.mli`, `lib/eta/schedule.mli` | Time values and recurrence policy |
| `lib/eta/queue.mli`, `lib/eta/channel.mli`, `lib/eta/pubsub.mli`, `lib/eta/semaphore.mli`, `lib/eta/pool.mli`, `lib/eta/portable_queue.mli` | Bounded handoff and admission primitives |
| `lib/eta/supervisor.mli`, `lib/eta/promise.mli`, `lib/eta/cause.mli` | Scope-bound concurrency and failure identity |
| `lib/stream/eta_stream.mli`, `lib/stream/docs/adrs/` | Source-like stream surface and resource ADRs |
| `lib/signal/eta_signal.mli`, `lib/signal_stream/eta_signal_stream.mli` | Adjacent graph substrate |
| `lib/observability/*.mli` | Tracer, logger, meter, sampler, log level, trace context |
| `lib/test/eta_test.mli`, `lib/test/eta_test.ml` | Test harness |
| `lib/crux/eta_crux.mli`, `lib/crux_test/eta_crux_test.mli`, `lib/crux/*.ml` | Eta Crux surface and its Eta substrate use |
| `test/crux/**` | Executable Eta Crux gates |
| `docs/wayfinder/eta-crux-capability-audit/issues/01` to `05` and their reports | Resolved baseline and censuses |

Evidence labels:

| Label | Meaning |
|---|---|
| Public contract | A promise in a public `.mli` or a tracked design document |
| Implementation detail | Behavior visible only in `.ml` code |
| Test-only control | A control that exists only in `eta_test` or `eta_crux_test` |
| Available substrate | The behavior exists in current Eta |
| Missing substrate | The behavior does not exist in current Eta |

## Surface inventory

| Surface | Public package | Public symbols | Role |
|---|---|---|---|
| Runtime | `eta` | `Eta.Runtime`, `Eta.Runtime_contract`, `Eta.Spi` | Interpreter, backend contract, service-provider hooks |
| Effect | `eta` | `Eta.Effect`, `Eta.Cause`, `Eta.Exit`, `Eta.Supervisor`, `Eta.Syntax` | Blueprints, failures, scopes, concurrency |
| Duration | `eta` | `Eta.Duration` | Millisecond time values |
| Schedule | `eta` | `Eta.Schedule` | Recurrence policy and step driver |
| Queue | `eta` | `Eta.Queue`, `Eta.Channel`, `Eta.Pubsub`, `Eta.Portable_queue`, `Eta.Semaphore`, `Eta.Pool` | Bounded handoff and admission |
| Supervisor | `eta` | `Eta.Supervisor` | Scope-bound child lifecycle |
| Source-like | `eta_stream`, `eta_signal_stream` | `Eta_stream.Stream`, `Eta_stream.Mailbox`, `Eta_stream.Sink`, `Eta_signal_stream` | Pull streams and bridges |
| Observability | `eta_observability` | `Eta_observability`, `Logger`, `Tracer`, `Meter`, `Log_level`, `Trace_context` | Spans, logs, metrics, sampling, propagation |
| Test | `eta_test` | `Eta_test.Test_clock`, `Eta_test.Run`, `Eta_test.Controlled`, `Eta_test.Expect`, `Eta_test.Test_random`, `Eta_test.Async` | Virtual clock, execution record, controlled calls |
| Crux test | `eta_crux_test` | `Handle`, `Incoming`, `Test_shell`, `Controlled_source`, `Recording_adapter` | Crux handle and dependency controls |

Package names come from the Dune metadata: [`lib/eta/dune`](../../../lib/eta/dune), [`lib/stream/dune`](../../../lib/stream/dune), [`lib/observability/dune`](../../../lib/observability/dune), [`lib/test/dune`](../../../lib/test/dune), [`lib/crux/dune`](../../../lib/crux/dune).

## Findings

### 1. Injected clocks and sleepers

The runtime clock is one monotonic pair: `now_ms` reads elapsed milliseconds, and `sleep` suspends on the same time base.

`Eta.Runtime.create_with_runtime` accepts `?sleep` and `?now_ms` overrides for the backend clock ([`lib/eta/runtime.mli`](../../../lib/eta/runtime.mli) lines 5-39).
The contract states that overriding one side is valid only when the other side uses the same monotonic clock (lines 26-30).
The functor shape `Eta.Runtime.Make` accepts the same overrides (lines 41-64).

The Eio backend exposes the same overrides in `Eta_eio.Runtime.create` ([`lib/eio/eta_eio.mli`](../../../lib/eio/eta_eio.mli) lines 99-120).
By default both sides use the supplied Eio clock.
The backend contract record and module shape declare `now_ms`, `sleep`, and `fresh` ([`lib/eta/runtime_contract.mli`](../../../lib/eta/runtime_contract.mli) lines 47-84 and 143-236).

The fiber-local override is `Eta.Effect.with_clock` ([`lib/eta/effect.mli`](../../../lib/eta/effect.mli) lines 707-717).
It replaces the clock pair for the wrapped effect, and children inherit it at fork.
The clock capability is the `Capabilities.clock` class with `now_ms` and `sleep` methods ([`lib/eta/capabilities.mli`](../../../lib/eta/capabilities.mli) lines 11-14).

Effect-level reads and sleeps use the pair:

| Operation | Source |
|---|---|
| `Effect.now_ms` | [`effect.mli`](../../../lib/eta/effect.mli) lines 498-501 |
| `Effect.sleep` | lines 518-521 |
| `Effect.delay`, `Effect.timed`, `Effect.timeout`, `Effect.timeout_as` | lines 523-534 |
| `Effect.retry`, `Effect.repeat` | lines 455-548 |
| `Effect.fresh`, `Effect.fresh_named` | lines 503-516 |

Schedule stepping takes an explicit `now_ms` input, and continuing steps sleep through the clock ([`lib/eta/schedule.mli`](../../../lib/eta/schedule.mli) lines 78-98).
The retry and repeat loops read the fiber-local clock and call its `sleep` between steps ([`lib/eta/effect_schedule.ml`](../../../lib/eta/effect_schedule.ml) lines 5-83).
Observability timestamps read the same clock ([`lib/eta/runtime_observability.ml`](../../../lib/eta/runtime_observability.ml) lines 314-361).

The adjacent graph substrate `Eta_signal.Time` samples the runtime clock once per stabilization ([`lib/signal/eta_signal.mli`](../../../lib/signal/eta_signal.mli) lines 686-745).
It offers `now`, `deadline`, `after`, and `interval` timer nodes.

**Available:** the monotonic clock pair, constructor overrides, fiber-local override, schedule stepping, and timer-backed signal nodes.
**Missing at Crux level:** no Crux graph clock, and no driver wake from a deadline.
The Crux `Driver.event` type has no deadline variant ([`lib/crux/eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 639-644).
The driver wake sources are the ingress queue, the request queue, and the terminal wake queue ([`lib/crux/crux_driver.ml`](../../../lib/crux/crux_driver.ml) lines 166-219 and 619-641).

### 2. Deterministic clock control in tests

`Eta_test.Test_clock` is a virtual monotonic clock ([`lib/test/eta_test.mli`](../../../lib/test/eta_test.mli) lines 9-38).

| Control | Behavior |
|---|---|
| `create` | Starts at millisecond 0 |
| `adjust` | Advances time and wakes due sleepers |
| `set_time` | Moves time to a target millisecond |
| `now_ms` | Reads the current virtual time |
| `sleeper_count` | Counts fibers waiting on the clock |
| `as_capability` | Exposes the pair to `Effect.with_clock` |

`Eta_test.with_test_clock` creates a runtime whose delay, timeout, repeat, and retry sleeps use the clock (lines 66-70).
`Eta_test.with_traced_test_clock` adds an in-memory tracer (lines 72-80).

`Eta_test.Run.run` executes one program on a fresh test runtime (lines 233-253).
Virtual sleeps advance automatically, so the run does not wait for wall time.
The outcome records the exit, ordered logs, spans, metrics, sleeps, and pending fibers (lines 196-231).
The determinism contract states that the same blueprint, initial clock, seed, and runtime construction produce the same exit and ordered observations (lines 246-253).
`Eta_test.Run.expect_sleeps` checks the complete ordered sleep history, and `expect_no_pending_fibers` checks the fiber census (lines 255-263).

`Eta_test.Test_random` supplies a deterministic random token, and `Effect.with_random` installs it fiber-locally (lines 173-179, [`effect.mli`](../../../lib/eta/effect.mli) lines 719-727).

Eta Crux tests already use these controls:

| Test file | Use |
|---|---|
| [`test/crux/races/test_eta_crux_races.ml`](../../../test/crux/races/test_eta_crux_races.ml) lines 41-778 | `Eta_test.with_test_clock` for Eta fiber time |
| [`test/crux/telemetry/test_eta_crux_telemetry.ml`](../../../test/crux/telemetry/test_eta_crux_telemetry.ml) lines 192-381 | `Eta_test.Run.run` and `~clock` for telemetry assertions |
| [`test/crux/laws/test_eta_crux_laws.ml`](../../../test/crux/laws/test_eta_crux_laws.ml) lines 3154-3218 | `Eta_test.Controlled` for dependency control |

**Available:** virtual clock with manual and automatic advancement, ordered sleep records, fiber census, and deterministic random.
**Missing at Crux level:** the `eta_crux_test` handle has no `advance_time` or clock control.
The `Handle` surface has `frame`, `drain`, `inject`, `poll`, `await`, `stop`, and delivery answers only ([`lib/crux_test/eta_crux_test.mli`](../../../lib/crux_test/eta_crux_test.mli) lines 29-123).
The test clock controls Eta fiber time, not Crux advancement cadence.

### 3. Effect names, annotations, identity, and lifecycle observations

`Effect.name` returns the leaf name of a blueprint, and `Effect.describe` renders the deterministic blueprint tree ([`lib/eta/effect.mli`](../../../lib/eta/effect.mli) lines 729-739).
The tree labels are `Pure`, `Fail`, `Custom`, `Custom("name")`, `Map`, and `Bind`.
A `Bind` shows its visible input subtree and a literal `<bind ...>` child.
The continuation is never forced.
The implementation renders these labels from the blueprint constructors ([`lib/eta/effect_core.ml`](../../../lib/eta/effect_core.ml) lines 1211-1269).
Named leaves exist for `bind_error`, `map_error`, `to_exit`, `or_die`, and `async` (lines 357-374).

Observability annotations attach to spans:

| Operation | Source |
|---|---|
| `named`, `fn` span names with source location | [`lib/observability/eta_observability.mli`](../../../lib/observability/eta_observability.mli) lines 51-63 and 356-368 |
| `annotate`, `annotate_all` string attributes | lines 65-73 |
| `event` structured markers | lines 88-91 |
| `with_result_attrs` outcome attributes | lines 93-118 |

The span record carries `span_id`, `parent_id`, `name`, `attrs`, `events`, `kind`, `status`, timestamps, and trace identifiers ([`lib/observability/tracer.mli`](../../../lib/observability/tracer.mli) lines 26-42).
Runtime defect capture copies the span name and annotations into the `Cause.die` record ([`lib/eta/cause.mli`](../../../lib/eta/cause.mli) lines 26-31).

Identity sources:

| Identity | Source |
|---|---|
| Runtime monotonic counter `Effect.fresh`, `fresh_named` | [`effect.mli`](../../../lib/eta/effect.mli) lines 503-516 |
| Fiber identity `Runtime_contract.current_fiber_id`, `with_fiber_identity` | [`runtime_contract.mli`](../../../lib/eta/runtime_contract.mli) lines 82-83 and 227-234 |
| Test fiber census with IDs and parentage | [`eta_test.mli`](../../../lib/test/eta_test.mli) lines 187-194 |
| Interruption identity `Cause.interrupt_id` | [`cause.mli`](../../../lib/eta/cause.mli) lines 19 and 65-72 |

Lifecycle observations:

| Observation | Source |
|---|---|
| Full exit materialization `Effect.to_exit` | [`effect.mli`](../../../lib/eta/effect.mli) lines 407-412 |
| `on_exit`, `on_error`, `on_interrupt` cleanup hooks | lines 572-604 |
| `finally` cleanup frame | lines 558-570 |
| `with_scope`, `acquire_release`, `with_resource` finalizers | lines 606-680 |
| `Cause.failures`, `Cause.defects`, `Cause.interruptors`, `Cause.pp_compact` | [`cause.mli`](../../../lib/eta/cause.mli) lines 147-205 |
| `Eta_test.Run.event` ordered cross-category observations | [`eta_test.mli`](../../../lib/test/eta_test.mli) lines 196-203 |

The Crux-level staged effect is an opaque `(unit, never) Eta.Effect.t` from `State_machine.create` ([`lib/crux/eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 50-63).
The staging test observes effect start through side-effect counters around `Post_commit.start`, not through effect inspection ([`test/crux/unit/test_eta_crux_core.ml`](../../../test/crux/unit/test_eta_crux_core.ml) line 102).

**Available:** blueprint names and descriptions, span names and attributes, events, defect diagnostics, fiber identity, interruption identity, exit hooks, and ordered test observations.
**Missing:** no public per-commit inventory of staged transition effects.
Opaque effects remain the default, and no command algebra exists.

### 4. Bounded queue policies and fairness

`Eta.Queue` offers four admission modes ([`lib/eta/queue.mli`](../../../lib/eta/queue.mli) lines 61-84).

| Mode | Policy |
|---|---|
| `unbounded` | No capacity limit |
| `bounded` | Backpressure: offers wait while full |
| `dropping` | Offers return `Dropped` when full |
| `sliding` | New values admit. Oldest buffered values drop |

Offer results are `Sent`, `Dropped`, `Full`, `Closed`, and `Closed_with_error` (lines 53-54).
`offer_all` returns the values not admitted by policy (lines 118-122).
`try_offer` returns `Full` instead of waiting (lines 130-134).
Graceful close keeps buffered values drainable.
`shutdown` drops them and wakes blocked operations (lines 173-191).
`stats` exposes depth, pressure, sent, received, dropped, closed state, and waiting counts (lines 33-51).

`Eta.Channel` is a same-domain bounded backpressure channel ([`lib/eta/channel.mli`](../../../lib/eta/channel.mli) lines 35-38).
Its ordering contract states FIFO buffered values and FIFO blocked-sender admission (lines 13-15).
It explicitly provides no scheduler fairness among fibers racing to call `send` or `recv`.

`Eta.Pubsub` has `Unbounded`, `Drop_new`, and `Backpressure` overflow policies ([`lib/eta/pubsub.mli`](../../../lib/eta/pubsub.mli) lines 13-46).
`Eta.Portable_queue` is a bounded MPSC queue with `Pushed`, `Full`, and `Closed` results and FIFO consumer order ([`lib/eta/portable_queue.mli`](../../../lib/eta/portable_queue.mli) lines 8-33).
`Eta_signal_stream.observe` bounds the bridge queue and drops the newest update when full, with an optional `on_drop` hook ([`lib/signal_stream/eta_signal_stream.mli`](../../../lib/signal_stream/eta_signal_stream.mli) lines 40-80).

Fairness facts:

- The queue waiter structures are FIFO queues in the implementation ([`lib/eta/queue.ml`](../../../lib/eta/queue.ml) lines 160-191).
- The handoff and admission primitives `Eta.Queue`, `Eta.Channel`, `Eta.Pubsub`, and `Eta.Portable_queue` offer no priority, reserved capacity, or coalescing.
- They also offer no per-endpoint isolation.

The Crux ingress is one root-wide bounded FIFO built on `Eta.Queue.bounded` ([`lib/crux/crux_root.ml`](../../../lib/crux/crux_root.ml) line 443).
The FIFO admission law A-02 has an executable property ([`test/crux/laws/test_eta_crux_laws.ml`](../../../test/crux/laws/test_eta_crux_laws.ml) line 1007).

**Available:** bounded, dropping, sliding, and backpressure policies.
It also has close and shutdown fences, FIFO waiter order, and the `Drop_new` pubsub and stream bridges.
**Missing:** `Eta.Queue`, `Eta.Channel`, `Eta.Pubsub`, and `Eta.Portable_queue` offer no priority, reserved capacity, coalescing, or per-endpoint capacity.
`Eta_signal` documents coalescing for observer delivery and timer sources, outside these primitives ([`lib/signal/eta_signal.mli`](../../../lib/signal/eta_signal.mli) lines 651-698).
The Crux ingress admits no class policy beyond the single FIFO.

### 5. Cancellation, scope, and resource protocols for host streams

`Eta_stream.Stream` is pull-based and chunked ([`lib/stream/eta_stream.mli`](../../../lib/stream/eta_stream.mli) lines 1-352).

| Source | Resource protocol |
|---|---|
| `from_eio_stream` | Caller owns the queue and producers. No end-of-stream marker (lines 219-222) |
| `from_queue` | Clean queue close ends the stream. `close_with_error` fails it (lines 224-226) |
| `from_file` | Opens and closes the descriptor. Downstream stop runs cleanup (lines 228-246) |
| `timeout` | Cancels the active upstream pull so source cleanup runs (lines 149-158) |
| `merge`, `flat_map_par` | Downstream completion cancels both upstream producers (lines 204-217) |

The timeout and merge implementations run producers as `Supervisor.scoped` children and cancel them ([`lib/stream/eta_stream.ml`](../../../lib/stream/eta_stream.ml) lines 989-1026).

`Eta_stream.Mailbox` is a bounded producer-side mailbox with `Enqueued`, `Dropped`, and `Closed` results ([`eta_stream.mli`](../../../lib/stream/eta_stream.mli) lines 264-297).
`Eta.Pubsub.subscribe` removes the subscription when the body succeeds, fails, or is cancelled ([`lib/eta/pubsub.mli`](../../../lib/eta/pubsub.mli) lines 58-66).
`Eta.Supervisor.Scope` provides `start`, `await`, `cancel`, and `request_cancel` for child lifecycle ([`lib/eta/supervisor.mli`](../../../lib/eta/supervisor.mli) lines 35-65).
`Eta.Effect` provides `with_background`, `with_supervised_background`, `uninterruptible`, `interruptible`, and `on_interrupt` ([`effect.mli`](../../../lib/eta/effect.mli) lines 267-283 and 595-695).

The `Eta_test.Controlled` canceler runs at most once when interruption wins ([`lib/test/eta_test.ml`](../../../lib/test/eta_test.ml) lines 337-357).
`Eta_crux.Source` owns a producer with emit and terminal actions ([`lib/crux/eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 76-97).
`Eta_crux_test.Controlled_source` controls incarnation open, emit, complete, fail, and cancel ([`lib/crux_test/eta_crux_test.mli`](../../../lib/crux_test/eta_crux_test.mli) lines 125-189).

**Available:** scoped child cancellation, scoped subscriptions, bounded mailboxes, queue-driven end markers, and Eio-descriptor cleanup in `from_file`.
**Missing:** a public generic owned effectful pull source with a finalizer.
The proposed `from_effect_reader` and `unfold_resource` constructors appear only in the proposed ADR ([`lib/stream/docs/adrs/0001-effect-reader-stream.md`](../../../lib/stream/docs/adrs/0001-effect-reader-stream.md) lines 23-52).
They do not exist in `eta_stream.mli`.
The Crux request contract is one-shot, so no many-response host operation exists (law R-01 in the baseline report, ticket `issues/13`).

### 6. Observability facilities for bounded diagnostics

Eta records structured log records, metric points, and spans ([`lib/eta/capabilities.mli`](../../../lib/eta/capabilities.mli) lines 73-80 and 144-166).
The span record is in [`lib/observability/tracer.mli`](../../../lib/observability/tracer.mli) lines 26-42.
The runtime fills `trace_id`, `span_id`, and `ts_ms` from the active span and clock.

Bounded-admission facilities:

| Facility | Source |
|---|---|
| `intercept_log` with `Keep`, `Drop`, `Replace` | [`eta_observability.mli`](../../../lib/observability/eta_observability.mli) lines 179-191 |
| `intercept_metric` with the same policy | lines 241-250 |
| `with_minimum_log_level` filter | lines 162-171 |
| `Sampler` span admission policies | [`lib/eta/sampler.mli`](../../../lib/eta/sampler.mli) lines 1-29 |
| `Tracer.retain_recent ~max` bounded test retention | [`lib/observability/tracer.mli`](../../../lib/observability/tracer.mli) line 51 |
| Meter summary `max_size` bounded window | [`capabilities.mli`](../../../lib/eta/capabilities.mli) lines 136-140 |

`Eta_test.Run` returns insertion-ordered logs, spans, metrics, sleeps, and a merged event record ([`lib/test/eta_test.mli`](../../../lib/test/eta_test.mli) lines 196-231).
The merged record preserves cross-category observation order.

The Crux telemetry is fixed spans, metrics, and logs through the root observability hooks ([`lib/crux/crux_telemetry.ml`](../../../lib/crux/crux_telemetry.ml) lines 23-167).
Crash diagnostics are failure snapshots from `Diagnostic.snapshot` and `State_machine.create ?diagnostics` ([`lib/crux/eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 38-63).
Telemetry tests capture Crux spans and metrics through `Eta_test.Run` ([`test/crux/telemetry/test_eta_crux_telemetry.ml`](../../../test/crux/telemetry/test_eta_crux_telemetry.ml) lines 192-381).

**Available:** structured records, span and metric admission control, scoped log filters, interceptors that drop records, bounded test-tracer retention, bounded summary windows, and failure snapshots.
**Missing:** no production bounded ring for log records.
The in-memory sinks collect unbounded snapshots ([`lib/observability/logger.mli`](../../../lib/observability/logger.mli) lines 26-32).
The meter sink is [`lib/observability/meter.mli`](../../../lib/observability/meter.mli) lines 42-47.
No bounded action history exists at the Crux level.
The baseline report classifies it as deliberately excluded.

## Candidate support map

### Reported gaps

| Gap ticket | Substrate surfaces involved | Available substrate | Missing substrate |
|---|---|---|---|
| `09` Graph time | Runtime clock, schedule, test clock | Clock pair, `with_clock`, `Schedule.step ~now_ms`, `Test_clock`, `Eta_signal.Time` | Crux deadline wake, `Handle` time control |
| `10` External graph input | Crux root, Eta_signal | Actions, construction closures, `Eta_signal.Var` | Crux root input parameter or live input API |
| `11` Startup facts and flags | Ordinary values | Construction input | No distinct flags concept in Eta or Crux |
| `12` Staged-effect observability | Effect, test harness | `Effect.name`, `Effect.describe`, `Run` events, `Controlled`, `Controlled_source`, `Recording_adapter` | Per-commit staged-effect inventory |
| `13` Host-owned streaming | Stream, queue, source | `Stream.from_queue`, `Mailbox`, `Pubsub`, `Eta_crux.Source` | Owned `from_effect_reader` source, many-response host operation |
| `14` Ingress admission classes | Queue, channel, pubsub | bounded, dropping, sliding, FIFO, Drop_new, Backpressure | Priority, reserved capacity, coalescing, per-endpoint capacity |
| `15` Pull observation | Crux driver, test handle | `Handle.last_output`, `Eta_signal.Observer.read` | Production Crux pull API |
| `16` Host-operation layers | Crux request path, observability | `Driver_event.handle` chain, observability interceptors | Middleware product (excluded) |
| `17` Action history and diagnostics | Observability, failure snapshots | spans, metrics, logs, `retain_recent`, summary `max_size`, `Diagnostic.snapshot` | Bounded action history, production log ring |

### Reference census candidates

The census reports classify 16 plausible generic roles per framework.
This table records the substrate that each candidate touches.
It does not decide the design.

| Candidate family | Census source | Available Eta substrate | Missing Eta substrate |
|---|---|---|---|
| Reactive graph values | Bonsai 1 | `Eta_signal` map family, `Eta_crux` computation | None at Crux graph level |
| External inputs and host variables | Bonsai 2, Elm 2 | `Eta_signal.Var`, actions, closures | Crux root input |
| State machines and actors | Bonsai 3, Rust Crux 1, Elm 3 | `Eta_crux.State_machine`, `Supervisor` | None |
| Model scope, reset, history | Bonsai 4 | `Eta_signal.Package.stable_family` | Crux-level scoped models |
| Dynamic structure | Bonsai 5 | `Eta_crux.Assoc`, `Eta_signal.Package` | None |
| Dynamic context | Bonsai 6 | `Runtime_contract.local`, `Effect.with_clock` pattern | Graph dynamic scope |
| Time | Bonsai 7, Rust Crux 18, Elm 11 | clock pair, `Eta_signal.Time`, `Test_clock` | Crux deadline wake |
| Lifecycle hooks | Bonsai 8 | `on_exit`, `on_interrupt`, `finally`, scopes | Per-frame hooks |
| Edge-triggered and polling | Bonsai 9 | `Stream.changes`, race, `Supervisor` | Latest-request-wins protocol |
| Effect concurrency and coordination | Bonsai 11 | `Effect.par`, `all_bounded`, `Semaphore` | One-at-a-time guard product |
| Host runtime integration | Bonsai 15, Rust Crux 3 | `Driver`, `Adapter`, `Hosted`, `Runtime` | None |
| Bidirectional sync and stability | Bonsai 17 | streams, queues, actions | Stability-duration protocol |
| Deterministic test driving | Bonsai 18, Elm 25 | `Test_clock`, `Run`, Crux `Handle` | Crux handle time control |
| Test observation and snapshots | Bonsai 19 | `Run` outcome, `Expect`, `Handle.last_output` | None |
| Test effects and input isolation | Bonsai 20, Elm 26 | `Controlled`, `Controlled_source`, `Recording_adapter` | None |
| Commands and orchestration | Rust Crux 5, Elm 4 | `Effect` combinators, `with_background` | Command product (excluded) |
| Streaming requests and subscriptions | Rust Crux 7, Elm 5 | `Stream.from_queue`, `Mailbox`, `Pubsub` | Owned pull source, many-response operation |
| Cancellation and task lifecycle | Rust Crux 8, Elm 7 | `Supervisor.Scope.cancel`, `uninterruptible`, `on_interrupt` | Shell cleanup protocol per capability |
| Middleware layers | Rust Crux 10 | observability interceptors, `Driver_event.handle` | Effect middleware product (excluded) |
| HTTP, key-value | Rust Crux 15, 17, Elm 12 | host operations, `Eta_http`, `Eta_sql` | None (capability packages) |
| Random and seeded execution | Elm 10 | `Capabilities.random`, `Test_random`, `with_random` | None |
| Pull observation of output | Rust Crux 2, Bonsai 19 | `Handle.last_output`, `Observer.read` | Production Crux pull API |
| Whole-program driver | Elm 25 | `Run`, Crux `Handle` | Crux handle time control |
| Simulated effects | Elm 26 | `Controlled`, `Recording_adapter` | Per-effect typed helpers |

## Ownership boundary

This section records which facts Eta owns and which facts Eta Crux must own.
It does not decide any capability design.

| Fact | Eta owns | Eta Crux must own |
|---|---|---|
| Monotonic clock pair semantics | Yes: `now_ms` and `sleep` form one time base ([`runtime.mli`](../../../lib/eta/runtime.mli) lines 26-30) | A graph clock must sample this pair. The deadline wake protocol is a Crux driver fact |
| Schedule stepping policy | Yes: `Schedule.step ~now_ms` and the sleep between steps ([`schedule.mli`](../../../lib/eta/schedule.mli) lines 86-91) | The decision that a deadline must wake the driver is a Crux driver fact |
| Queue admission mechanics | Yes: bounded, dropping, sliding, close and shutdown fences ([`queue.mli`](../../../lib/eta/queue.mli) lines 61-191) | Ingress FIFO law A-02 and any class policy are Crux graph facts |
| Fiber cancellation and finalizers | Yes: scopes, masks, `finally`, `on_exit`, `with_scope` | Request cardinality R-01 and any shell cleanup protocol are Crux protocol facts |
| Blueprint names and descriptions | Yes: `Effect.name`, `Effect.describe` | The opaque staged-effect boundary and any per-commit observation are Crux graph facts |
| Observability capabilities | Yes: tracer, logger, meter, sampler, interceptors | The fixed telemetry names and failure snapshots are Crux facts |
| Test harness | Yes: `Test_clock`, `Run`, `Controlled`, fiber census | The Crux handle semantics, such as `last_output`, are Crux test facts |
| Stream pull and source finalization | Yes for Eta-constructed sources such as `from_file` and `from_queue` | Host stream binding and desired-set reconciliation are Crux host facts |
| Startup flags and external graph input | No dedicated substrate exists or is needed | Crux or the application owns the typed contract, if any |

## Missing substrate summary

The following substrate does not exist in current Eta.
Evidence for absence is the absence of the named symbol or contract in the cited public surface.

| Missing substrate | Evidence for absence |
|---|---|
| Crux driver deadline wake | `Driver.event` has no deadline variant ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 639-644). Driver wakes on ingress, request, and terminal queues only ([`crux_driver.ml`](../../../lib/crux/crux_driver.ml) lines 619-641) |
| Crux test-handle time control | `eta_crux_test` `Handle` has no clock or `advance_time` ([`eta_crux_test.mli`](../../../lib/crux_test/eta_crux_test.mli) lines 29-123) |
| Generic owned effectful pull source | `from_effect_reader` and `unfold_resource` exist only in the proposed ADR, not in `eta_stream.mli` ([`0001-effect-reader-stream.md`](../../../lib/stream/docs/adrs/0001-effect-reader-stream.md) lines 23-52) |
| Many-response host operation | Crux requests are one-shot (law R-01). The streaming request is excluded |
| Admission classes | No priority, reserved capacity, coalescing, or per-endpoint capacity in `Eta.Queue`, `Eta.Channel`, `Eta.Pubsub`, or `Eta.Portable_queue` |
| Per-commit staged-effect inventory | `State_machine.create` returns an opaque effect ([`eta_crux.mli`](../../../lib/crux/eta_crux.mli) lines 50-63). No command algebra exists |
| Bounded action history | Explicitly excluded in the baseline report. No history module exists in `eta_crux` or `eta_crux_test` |
| Production bounded log ring | `Logger.in_memory` returns an unbounded snapshot list ([`logger.mli`](../../../lib/observability/logger.mli) lines 26-32) |
| Middleware product | Explicitly excluded. Only observability interceptors exist |

## Uncertainty

1. `Eta_signal` and `Eta_signal_stream` are adjacent graph substrates, not part of `eta_crux`.
   Whether they become Crux substrate is a design decision, not a substrate fact.
2. The queue implementation uses FIFO waiter structures.
   The public `queue.mli` does not promise waiter fairness in prose.
   The `channel.mli` does.
3. Line ranges cite the current worktree state.
   The worktree can change after this report is written.
4. This report inspected present source and did not re-run the test suite.
   The named tests are present files with the cited names and locations.
