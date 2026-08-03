# Failure, defect, and crash boundary

Type: grilling
Status: resolved
Blocked by: 05, 07, 08

## Question

How do expected failures, defects, interruption, and cleanup failures cross Eta
Crux computation, driver, and adapter boundaries?

Decide:

- which failures are ordinary action or model values.
- how action-routed expected failures remain distinct from effect defects and
  interruption.
- which framework operations have their own typed errors.
- what a transition exception or `eta_signal` invariant failure does.
- whether a defect stops one dynamic scope or the whole application.
- whether automatic restart exists at any level.
- how `Cause` and suppressed cleanup failures reach the hosted runner and
  explicit driver.
- what diagnostic context is stable and safe to retain.

Source opening and producer typed failures already become terminal actions.
Source defects, finalizer failures, and sends after closed ingress still need
the root and driver rules from this ticket.

The design must fail loudly without one catch-all error type. It must preserve
Eta's typed failure, defect, interruption, and resource-cleanup distinctions.

## Answer

### Classification

Expected operation failures remain application values. Source opening and
producer failures become terminal actions before they leave their source work.
An endpoint admission failure remains a typed framework error.

Pure disposal interruption and host-requested interruption are normal lifetime
outcomes. An interruption-only `Eta.Cause` never starts the crash path. Every
other cause that escapes Eta Crux-owned work starts a root crash.

Transition exceptions, `eta_signal` invariant failures, and structural preflight
failures commit nothing from the active advancement. Eta Crux publishes no
output and starts none of its staged work. V1 provides no automatic restart.

### Endpoint admission

Endpoint admission has one core error:

```ocaml
module Endpoint : sig
  type 'message t
  type admission_error = Ingress_closed

  val send :
    'message t ->
    'message ->
    (unit, admission_error) Eta.Effect.t
end
```

`Ok ()` means that the queue accepted the message. It does not promise that a
later advancement processes the message. Shutdown can discard an accepted,
queued message.

`Endpoint.send` waits while the bounded ingress queue is full. Exported
nonblocking invocation reports `Full` in a separate capacity result.

Admission and ingress closure use atomic first-winner arbitration. Closure
returns `Ingress_closed` without queueing the message. This expected error is
not an interruption, defect, or root failure.

The producer of a typed-infallible staged effect handles `Ingress_closed`
explicitly. Nonblocking exported admission has a separate capacity error.
[Exported endpoint and handle contract](16-exported-endpoint-contract.md) owns
that adapter-facing result.

Endpoint incarnation validation remains an advancement operation. A message can
enter an open root before an earlier message disposes its target. Its later
advancement returns `Rejected Stale_endpoint`.

### Failure data

The semantic failure data is:

```ocaml
module Failure : sig
  type packed_eta_cause
  type cell_id
  type endpoint_id
  type trigger_kind
  type observation_position
  type diagnostic_snapshot

  type origin =
    | Transition
    | Owned_work
    | Adapter_delivery
    | Export_dispatch
    | Cleanup
    | Crash_handler

  type record = {
    cause : packed_eta_cause;
    origin : origin;
    cell : cell_id option;
    endpoint : endpoint_id option;
    trigger : trigger_kind;
    position : observation_position;
    action_snapshot : diagnostic_snapshot option;
    model_snapshot : diagnostic_snapshot option;
  }

  type t = {
    primary : record;
    secondary : record list;
  }

  type settlement = {
    failure : t;
    teardown_settled : bool;
  }
end
```

`Transition` covers synchronous transition, stabilization, and structural
preflight failures. `Owned_work` covers admitted transition effects, lifecycle
programs, and source work.

`Adapter_delivery` covers committed output delivery. `Cleanup` covers failures
from root teardown. `Crash_handler` covers the application crash handler and its
diagnostic hooks.

`Export_dispatch` covers defects from exported payload decoders and narrowed
endpoint mappers. Synchronous invocation latches root crash, closes ingress, and
then re-raises the defect.

`packed_eta_cause` retains the original `Eta.Cause` tree and its hidden error
type. Eta Crux does not flatten the tree or replace it with an exception string.
The final API prototype owns the safe existential package and portable view.

The first observed fatal record is the immutable primary record. Later fatal
records append to `secondary` in observation order. The position is a root-local
monotonic value.

Observation order does not prove causal order. Eta Crux never creates a
`Cause.Sequential` or `Cause.Concurrent` node for separately observed records.
Each record keeps the causal structure that Eta supplied.

Every record contains its origin and trigger kind. Cell and endpoint identities
are present when that origin has them. A missing identity is explicit `None`.

Action and model payloads appear only through explicit redacted diagnostic
hooks. Eta Crux adds no raw typed action, closure, model, or host handle to a
report. A missing hook produces `None`.

A diagnostic hook failure becomes secondary crash-handler evidence. The failed
snapshot remains absent. This rule keeps report construction from replacing the
primary failure.

### Root crash entry

The first fatal record atomically latches the root crash. The root then closes
ingress, discards queued messages, wakes the driver, and emits one detection
observation.

A synchronous advancement failure returns `Failed` with the detection and one
mandatory post-commit batch. An asynchronous failure wakes the driver. The next
eligible `advance` returns the same form.

The failure batch performs complete root teardown. The root never advances
application messages after the fatal latch. A stop request cannot replace a
latched crash.

### Commit and terminal races

Advancement commit and asynchronous fatal detection share one atomic commit
boundary. Their first winner determines the result.

If fatal detection wins, Eta Crux discards the staged model, graph, output, and
effects. The active `advance` returns `Failed` with the failure batch.

If commit wins, `Committed` remains valid and its output remains eligible for
delivery. The existing batch changes into crash teardown before its ordinary
work starts.

A stop request and the start of a pending commit batch also use first-winner
arbitration. If stop wins, the existing batch changes into root teardown. If
start wins, ordinary admission finishes before stop teardown starts.

A fatal record changes any unstarted ordinary or stop batch into crash teardown.
An adapter output-delivery failure before batch start uses this path with origin
`Adapter_delivery`. Eta Crux does not retry the output or start ordinary batch
work.

Output delivery happens after core commit. Therefore, delivery failure cannot
roll back the committed model, graph, or output value. The crash report records
this distinction through its origin.

### Batch protocol

Each batch token has one runtime state: `pending`, `starting`, or `started`.
Starting changes `pending` to `starting` atomically. Complete admission changes
`starting` to `started`.

A second start returns `Already_started`. Stop and crash never invalidate a
token. They change the work that its first start performs.

The terminal batch settles the complete tracked root tree. It interrupts owned
work, awaits every child and finalizer, and preserves Eta cleanup causes.
[Dynamic lifetime and work ownership](07-dynamic-lifetime-ownership.md) defines
the structural cancellation and settlement order.

A cleanup failure during normal stop changes the terminal result from `Stopped`
to `Crashed`. That cleanup record becomes the primary failure. A cleanup failure
during crash appends one secondary record.

### Detection and settlement

Crash observation has two distinct values. Detection contains the immutable
primary failure and all secondary records observed at that point. Final
settlement contains the same primary, the complete secondary list, and
`teardown_settled = true`.

The application crash handler receives detection once. A handler failure becomes
secondary evidence with origin `Crash_handler`. Eta Crux then invokes the
built-in minimal reporter once and never calls the application handler again for
that crash.

Hosted and explicit drivers observe detection and final settlement through the
same root protocol. A crash batch does not finish before complete teardown
settles. [OCaml API syntax and ergonomics](14-ocaml-api-ergonomics.md) owns the
exact result nesting.

### Internal representation

The runtime uses one closed internal phase variant:

```ocaml
type phase =
  | Ready
  | Advancing
  | Advancing_stop_requested
  | Advancing_crash_requested of Failure.t
  | Awaiting_commit of batch
  | Stop_pending
  | Crash_pending of Failure.t
  | Awaiting_stop of batch
  | Awaiting_crash of Failure.t * batch
  | Starting_commit of batch
  | Starting_commit_stop_requested of batch
  | Starting_commit_crash_requested of Failure.t * batch
  | Tearing_down_stop of batch
  | Tearing_down_crash of Failure.t * batch
  | Replacing_session of session_replacement * terminal_request
  | Awaiting_session_delivery of session_delivery * terminal_request
  | Closed of terminal

and terminal_request =
  | No_terminal_request
  | Stop_requested
  | Crash_requested of Failure.t

and terminal =
  | Stopped
  | Crashed of Failure.settlement
```

This variant makes phase transitions exhaustive inside the runtime. Public
phantom-state handles do not provide the same guarantee because callers can
alias handles and failures arrive asynchronously.

An internal GADT still needs runtime matching after existential state packaging.
The closed variant keeps that matching direct. The separate atomic batch state
enforces one start across shared aliases.

Session replacement records stop or crash requests in `terminal_request`. A
crash request replaces a stop request and preserves the first fatal record.

A crash while replacement waits aborts the replacement after dispatch permits
settle. Eta Crux closes the candidate registry and moves to `Crash_pending`.

`Awaiting_session_delivery` represents the delivery fence for replacement
output. [Generic host adapter contract](10-generic-host-adapter.md) owns its exact
acknowledgment operation.

### Prototype evidence

The selected prototype is on branch `prototype/eta-crux-failure-state` at commit
`96b90d11`:

- [root failure-state prototype](https://github.com/ribelo/eta/tree/96b90d11/.scratch/prototypes/eta-crux-failure-state)

The prototype covers normal commit, transition failure, asynchronous failure,
stop races, delivery failure, cleanup failure, concurrent fatal observations,
and repeated batch start. It compiles under OxCaml and upstream OCaml 5.4.

### Rejected alternatives

Eta Crux does not restart one child after an escaping cause. It does not flatten
causes, infer causal relations from observation order, or replace the primary
failure after cleanup.

Root typestate does not enter the public API. Stop does not discard or invalidate
a pending batch. Closed endpoint admission does not fabricate interruption or a
defect.
