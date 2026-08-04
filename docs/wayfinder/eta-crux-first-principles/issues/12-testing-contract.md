# Deterministic testing contract

Type: grilling
Status: resolved
Blocked by: 04, 06, 07, 08, 09, 11, 18

## Question

What test surface follows naturally from typed computations and deterministic
advancement, without creating a second runtime semantics?

Decide how tests:

- construct a root with inputs and dependencies.
- inject typed actions and advance one transaction.
- inspect typed root output and explicit adapter reconciliation.
- intercept, execute, cancel, or provide results for staged Eta effects.
- control time and long-lived sources.
- assert dynamic activation, disposal, keyed identity, and stale injection.
- assert typed failures, defects, and cleanup causes.
- arbitrate ingress closure against endpoint admission.
- arbitrate commit against fatal detection and batch start against stop.
- inspect primary failures, ordered secondary records, and final settlement.
- request exhaustive checks without depending on internal node structure.
- test a host adapter through a recording fake.

The test package must use the production advancement primitive. It must not
identify effects by anonymous function identity or duplicate the Eta runtime.

## Answer

### Boundary

Eta Crux has one thin test handle over the production `Root` and `Driver`.
The handle does not implement transitions, stabilization, effect execution, or
request dispatch.

Application tests construct an ordinary application description with ordinary
OCaml arguments. They create a production root with explicit ingress and request
capacities. `Handle.create` then takes exclusive protocol ownership of that root.

This ownership is a contract because OCaml values are not linear. A caller must
not advance the root or create another driver while the handle is live.

The handle exposes low-level forwarding operations for each production driver
phase. These operations return the production events and one-shot tokens. The
handle does not expose a raw driver accessor.

Low-level delivery completion must also go through the handle. This rule keeps
the handle's latest delivered output correct.

`Handle.use` brackets one handle lifetime. Its finalizer requests stop and
settles the root when the test did not already settle it.

Implicit cleanup expects `Stopped`. An unobserved `Crashed` result fails the test
with the complete settlement. A crash test consumes its terminal result before
the bracket ends.

### Semantic surface

The test surface has this semantic shape. Final module placement belongs to
[Package and module boundaries](15-package-boundaries.md).

```ocaml
module Eta_crux_test : sig
  module Incoming : sig
    type ('output, 'incoming) t

    val create :
      send:
        ('output ->
         'incoming ->
         (unit, Endpoint.admission_error) Eta.Effect.t) ->
      ('output, 'incoming) t

    val none : ('output, Eta_crux.never) t
  end

  module Test_shell : sig
    type ('output, 'error) t = {
      pp_error : Format.formatter -> 'error -> unit;
      deliver :
        'output Adapter.delivery ->
        (unit, 'error) Eta.Effect.t;
      request_event :
        Request.Driver_event.t ->
        (unit, 'error) Eta.Effect.t;
      crash_detected :
        Failure.t ->
        (unit, 'error) Eta.Effect.t;
    }
  end

  module Handle : sig
    type ('output, 'incoming) t
    type operation_error = Busy
    type inject_error = No_output | Ingress_closed

    type 'output frame_outcome =
      | Idle
      | Rejected of Root.delivery_error
      | Committed of 'output
      | Stopped
      | Crashed of Failure.settlement

    type 'output frame = {
      outcome : 'output frame_outcome;
      events : 'output Driver.event list;
    }

    type drain_status =
      | Idle
      | Limit_reached
      | Closed of Driver.terminal

    type 'output drain = {
      status : drain_status;
      events : 'output Driver.event list;
    }

    val create :
      incoming:('output, 'incoming) Incoming.t ->
      shell:('output, 'shell_error) Test_shell.t ->
      'output Root.t ->
      ('output, 'incoming) t

    val use :
      incoming:('output, 'incoming) Incoming.t ->
      shell:('output, 'shell_error) Test_shell.t ->
      'output Root.t ->
      f:
        (('output, 'incoming) t ->
         ('result, 'body_error) Eta.Effect.t) ->
      ('result, 'body_error) Eta.Effect.t

    val last_output : ('output, 'incoming) t -> 'output option

    val inject :
      ('output, 'incoming) t ->
      'incoming ->
      (unit, inject_error) Eta.Effect.t

    val frame :
      ('output, 'incoming) t ->
      (('output frame, operation_error) result, Eta_crux.never) Eta.Effect.t

    val drain :
      ('output, 'incoming) t ->
      max_steps:int ->
      (('output drain, operation_error) result, Eta_crux.never) Eta.Effect.t

    val stop :
      ('output, 'incoming) t ->
      ((Driver.terminal, operation_error) result, Eta_crux.never) Eta.Effect.t

    val poll :
      ('output, 'incoming) t ->
      (('output Driver.event option, operation_error) result, Eta_crux.never)
        Eta.Effect.t

    val await :
      ('output, 'incoming) t ->
      (('output Driver.event, operation_error) result, Eta_crux.never) Eta.Effect.t

    val delivery_delivered :
      ('output, 'incoming) t ->
      'output Driver.Delivery.t ->
      ((unit, Driver.Delivery.completion_error) result, Eta_crux.never)
        Eta.Effect.t

    val delivery_failed :
      ('output, 'incoming) t ->
      'output Driver.Delivery.t ->
      Failure.Packed_cause.t ->
      ((unit, Driver.Delivery.completion_error) result, Eta_crux.never)
        Eta.Effect.t

    val request_stop : ('output, 'incoming) t -> unit
  end
end
```

The shell error type is existential inside the handle. A shell callback failure
enters the root failure protocol instead of the body effect's typed error.

`poll`, `await`, `delivery_delivered`, `delivery_failed`, and `request_stop` are
the low-level forwarding surface. Callers use these operations instead of the
aliased root while the handle owns it.

The production telemetry contract makes `poll`, `delivery_delivered`, and
`delivery_failed` typed-infallible Eta effects. The test handle forwards those
effects without adding an observer path.

`Incoming.none` uses the uninhabited `Eta_crux.never` type. It avoids an
optional weak type variable for roots that accept no test input.

`Handle.drain` raises `Invalid_argument` when `max_steps <= 0`. There is no
default limit.

`Incoming.create` maps one test input through the latest successfully delivered
output. The mapping must call a production endpoint. It cannot place an action
directly in the ingress queue. Export tests call the production export operation.

Injection before the first successful delivery returns `No_output`. Each call
injects one value. There is no list operation that can deadlock against bounded
ingress before advancement starts.

Endpoint admission uses the production Eta effect. Thus, capacity waiting,
ingress closure, endpoint incarnation, FIFO order, and driver wake behavior stay
unchanged.

### One frame

One frame performs at most one root advancement. It uses the stable test shell
to complete output delivery and crash notification.

The frame can first handle request handoffs that production priority places
before the next advancement. These handoffs do not count as another
advancement.

A committed frame stops after complete post-commit admission. It does not wait
for transition effects, lifecycle programs, sources, or host requests to finish.
It does not drain events that this work emits later.

The frame returns its closed outcome and the exact public driver events that its
test shell handled. One-shot tokens in this list are already answered. A second
answer returns the production completion error.

An output-delivery callback failure uses `Adapter_delivery`. A request callback
failure uses `Request_dispatch`. A crash callback failure becomes secondary
`Crash_handler` evidence.

The callback error type and printer produce the same packed Eta cause as the
production adapter boundary. The test handle adds no failure classification.

Only one high-level handle operation can be active. A concurrent frame, drain,
or stop call returns `Busy`. The handle does not hide this error behind a mutex.

### Bounded draining and stop

A bounded drain follows the production driver loop. It requires a positive step
limit and a handler for every public driver event.

The handler must answer delivery, request, and crash events. It cannot silently
accept output or reject requests.

The drain returns the exact handled event list. Its status is `Idle`,
`Limit_reached`, or `Closed terminal`.

The limit bounds self-sustaining action cycles. A limit result leaves the handle
valid, so a test can inspect the events and continue.

The stop helper requests production shutdown and handles the remaining events.
It returns the production terminal value after complete root settlement. Tests
can use the low-level operations when they need to stop between two driver
phases.

There is no `run_until_stable` operation. Long-lived sources can keep valid work
alive, and application actions can intentionally sustain a cycle.

### Eta effects and controlled dependencies

In-process Eta effects run on the real Eta runtime. Tests control their typed
dependencies instead of intercepting anonymous effect closures.

The caller owns the Eta test scope. Eta Crux composes with
`Eta_test.Test_clock`, `Eta_test.Async`, and `Eta_test.Expect`. It adds no clock,
scheduler, promise runtime, or cause assertion layer.

Eta gains one general controlled-effect helper because this facility is not
specific to Eta Crux:

```ocaml
module Eta_test.Controlled : sig
  type ('input, 'output, 'error) t
  type ('input, 'output, 'error) call
  type completion_error = Not_pending

  type status =
    | Pending
    | Succeeded
    | Failed
    | Died
    | Cancelled

  val create : unit -> ('input, 'output, 'error) t
  val effect :
    ('input, 'output, 'error) t ->
    'input ->
    ('output, 'error) Eta.Effect.t

  val poll_call :
    ('input, 'output, 'error) t ->
    ('input, 'output, 'error) call option

  val await_call :
    ('input, 'output, 'error) t ->
    (('input, 'output, 'error) call, 'never) Eta.Effect.t

  val input : ('input, 'output, 'error) call -> 'input
  val status : ('input, 'output, 'error) call -> status

  val succeed :
    ('input, 'output, 'error) call ->
    'output ->
    (unit, completion_error) result

  val fail :
    ('input, 'output, 'error) call ->
    'error ->
    (unit, completion_error) result

  val die :
    ('input, 'output, 'error) call ->
    exn ->
    (unit, completion_error) result

  val expect_no_pending : ('input, 'output, 'error) t -> unit
end
```

Calls enter one FIFO observation queue. Each call has typed input and one-shot
completion authority. Test-side operations inspect the input, await a call,
succeed it, fail it, or make it die with an exception.

Interruption comes only from real Eta cancellation. A test cannot fabricate an
interruption identity.

Completion and cancellation use first-winner arbitration. A later completion
returns `Not_pending`. The call status records which outcome won.

The observation queue has no artificial capacity. It is test bookkeeping, not
an application queue. `expect_no_pending` detects calls that a test forgot.

This helper follows the controlled-dependency pattern in Bonsai. It does not
turn all Eta effects into Rust Crux commands.

### Host requests

Host requests use a separate shell seam. An integration binds each typed
`Host_operation` descriptor to a controlled handler before it creates the root.

The handler installs typed response and cancellation paths before it accepts
dispatch. The test can then:

- inspect the typed request.
- resolve one typed response.
- reject dispatch.
- observe framework cancellation.

This is the Rust Crux pattern at the boundary where it fits. Tests do not unpack
opaque request events, encode frames, or replace in-process Eta effect semantics.

Inbound request tests call the production `Request_export` operation. Late and
duplicate response checks use the production responder and `Not_pending` result.

### Controlled sources and time

`eta_crux_test` provides a controlled producer for the production `Source`
protocol. Every opening creates one typed incarnation handle.

```ocaml
module Eta_crux_test.Controlled_source : sig
  type ('spec, 'item, 'error) t
  type ('spec, 'item, 'error) incarnation

  type state =
    | Opening
    | Running
    | Completed
    | Failed
    | Cancelled

  type control_error = Wrong_state of state
  type emit_error =
    | Control of control_error
    | Admission of Endpoint.admission_error

  val create : unit -> ('spec, 'item, 'error) t

  val producer :
    ('spec, 'item, 'error) t ->
    'spec ->
    ('item, 'error) Source.producer

  val poll_incarnation :
    ('spec, 'item, 'error) t ->
    ('spec, 'item, 'error) incarnation option

  val await_incarnation :
    ('spec, 'item, 'error) t ->
    (('spec, 'item, 'error) incarnation, Eta_crux.never) Eta.Effect.t

  val spec : ('spec, 'item, 'error) incarnation -> 'spec
  val state : ('spec, 'item, 'error) incarnation -> state

  val open_ :
    ('spec, 'item, 'error) incarnation ->
    (unit, control_error) result

  val fail_open :
    ('spec, 'item, 'error) incarnation ->
    'error ->
    (unit, control_error) result

  val emit :
    ('spec, 'item, 'error) incarnation ->
    'item ->
    (unit, emit_error) Eta.Effect.t

  val complete :
    ('spec, 'item, 'error) incarnation ->
    (unit, control_error) result

  val fail :
    ('spec, 'item, 'error) incarnation ->
    'error ->
    (unit, control_error) result

  val captured_emitter :
    ('spec, 'item, 'error) incarnation ->
    'item Source.emit option

  val expect_no_pending : ('spec, 'item, 'error) t -> unit
end
```

An incarnation exposes these states:

- `Opening`.
- `Running`.
- `Completed`.
- `Failed`.
- `Cancelled`.

The test controls opening success or typed opening failure. After successful
opening, it controls item emission and producer completion or typed failure.
Invalid operations return explicit state errors.

Each handle records its spec and incarnation. An equal spec produces no new
handle. A changed spec or a fresh active interval produces a new handle.

Normal controller emission stops after terminal outcome or cancellation. The
helper also exposes the captured production emitter for deliberate stale-capability
tests.

An old emitter still uses production admission and incarnation validation. It
does not receive a test-only stale result before advancement.

Tests adjust `Eta_test.Test_clock` directly. Clock movement does not advance Eta
Crux. The test explicitly runs a later frame or drain.

### Lifecycle, identity, and failures

Application tests inspect only public semantic evidence:

- canonical typed root outputs.
- retained old endpoints and exports.
- controlled-effect and controlled-source calls.
- test-owned logs inside effects and resource finalizers.
- production driver events.
- production failures and settlement.

A keyed test keeps an old endpoint, removes its key, and advances the old
message. It expects `Rejected Stale_endpoint`. Re-entry uses a fresh endpoint
and fresh model output.

Activation and disposal tests record their own effect starts, interruption, and
finalizers. Eta Crux exposes no probe channel, graph dump, node registry, scope
registry, or model inspector.

Failure helpers match production records by:

- the packed-cause predicate.
- origin and trigger.
- optional cell and endpoint identities.
- optional diagnostic snapshots.
- exact ordered secondary records.

Settlement helpers require the expected primary record, complete secondary
list, and `teardown_settled = true`. They do not normalize or compare formatted
failure strings.

### Exhaustive checks

Exhaustiveness applies to finite observations from one operation. A frame or
bounded drain can be compared with one exact expected event list.

Helpers such as `expect_one` and `expect_empty` reject missing and extra values.
Each controlled dependency and source has its own `expect_no_pending` check.

There is no global controller registry and no whole-test transcript cursor. A
live concurrent runtime has no finite global observation batch.

Eta Crux adds no property-test language. QCheck and ordinary Alcotest cases can
compose the same typed handle operations. Internal generated laws remain useful
for pure or bounded properties.

### Adapter tests

Adapter testing is separate from core handle testing. A recording
`Adapter.resource` records these calls in order:

- acquire.
- output delivery.
- request event.
- crash detection.
- release.

Each controlled response can succeed, fail, or block. The recorder preserves
delivery reasons and the production callback error boundary.

The generic recorder does not infer host mutations from root output. A concrete
adapter uses a toolkit-specific fake to record scheduling, reconciliation, host
events, and toolkit operations.

### Private law tests

Three atomic race families need deterministic internal tests:

- endpoint admission against ingress closure.
- advancement commit against fatal latching.
- post-commit batch start against stop request.

Each law test covers both winners. Private one-shot barriers stop a contender
immediately before the real linearization point. No barrier callback runs while
a root lock is held.

The production operation and arbitration algorithm remain unchanged. These
barriers are not part of `eta_crux_test` or the application contract.

Internal conformance tests also run one scenario through identity and serialized
bindings. The public test package exposes no transport-conformance DSL.

### Rejected alternatives

Eta Crux has no synchronous transition simulator, pending-command wrapper, or
test-only state transition path.

The test surface has no mandatory global transcript, framework probe event,
public race checkpoint, graph snapshot, automatic delivery success, unbounded
drain, or property-test DSL.

The selected design follows the reference evidence in
[Bonsai and Rust Crux testing surfaces](../../../../.scratch/research/eta-crux/testing-reference-surfaces.md).
Bonsai supplies the production-driver handle model. Rust Crux supplies the typed
shell-request control model.
