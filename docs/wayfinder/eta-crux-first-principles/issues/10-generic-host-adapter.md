# Generic host adapter contract

Type: prototype
Status: resolved
Blocked by: 06, 08, 09, 11, 16, 19

## Question

What is the smallest host-neutral contract between a running Eta Crux
application and a renderer or other external host?

Use Sliml as one falsifier, not as the interface template. The contract must
show:

- host event conversion into typed injection.
- delivery and adapter-owned reconciliation of the canonical root result.
- host-thread scheduling without exposing host handles to Eta Crux.
- startup, wake, stop, and ordered teardown.
- typed `Ingress_closed` admission and adapter capacity reporting.
- fatal output-delivery reporting before post-commit start.
- immediate crash detection and final teardown settlement.
- serialized-session replacement, current-output redelivery, and its advancement
  fence.
- one same-domain host and one foreign-loop retained host.
- a recording fake that verifies the adapter without its toolkit.

Host-owned event systems expose the generic two-phase producer from
[Long-lived sources and subscriptions](08-subscriptions-and-sources.md). The
adapter reports readiness after it installs the host event path. Eta Crux still
owns source identity, reconciliation, and cancellation.

Determine which operations belong to Eta Crux, to a generic adapter helper, and
to a concrete package such as `eta_crux_sliml`. The core must not acquire a
renderer, serialization format, or Sliml value model.

[Failure, defect, and crash boundary](11-failure-boundary.md) fixes the semantic
failure outcomes. This ticket owns their host-neutral callback and scheduling
surface.

## Answer

### Boundary shape

Eta Crux exposes a pull-based `Driver` over one `Root`. An optional `Hosted`
helper consumes the same driver events.

The semantic driver surface is:

```ocaml
module Driver : sig
  type 'output t

  type terminal =
    | Stopped
    | Crashed of Failure.settlement

  module Delivery : sig
    type reason =
      | Advancement
      | Session_replacement

    type 'output t
    type completion_error = Already_completed

    val output : 'output t -> 'output
    val reason : 'output t -> reason
    val delivered : 'output t -> (unit, completion_error) result

    val failed :
      'output t ->
      Failure.Packed_cause.t ->
      (unit, completion_error) result
  end

  type 'output event =
    | Deliver of 'output Delivery.t
    | Rejected of Root.delivery_error
    | Crash_detected of Failure.t
    | Closed of terminal

  type replace_error =
    | Already_advancing
    | Awaiting_delivery
    | Terminating
    | Closed

  val create : 'output Root.t -> 'output t
  val poll : 'output t -> 'output event option
  val await : 'output t -> ('output event, Eta_crux.never) Eta.Effect.t
  val request_stop : 'output t -> unit

  val replace_serialized_session :
    'output t ->
    Serialized_session.candidate ->
    ('output Delivery.t, replace_error) result
end
```

`poll` performs available driver work without waiting. `await` waits on the root
wake when the root is idle. Eta Crux calls no host wake callback.

Each operation performs at most one root advancement. A stale endpoint produces
`Rejected Stale_endpoint`. The driver never hides that advancement by selecting
another action.

### Delivery token

One delivery token answers one output-delivery question. The adapter reports
`Delivered` or one complete Eta cause.

The answer does not run root work. The next `poll` or `await` starts the applicable
post-commit, replacement, stop, or crash batch.

An advancement delivery success starts its post-commit batch. A replacement
delivery success lifts the session-delivery fence.

A delivery failure latches a root crash with origin `Adapter_delivery`. It closes
ingress and suppresses ordinary post-commit work before that work can start.

Each token completes at most once. A second answer returns `Already_completed`.

If a crash arrives while output awaits delivery, the root latches it and closes
ingress immediately. The committed output remains eligible.

After delivery finishes, the driver emits `Crash_detected`. It starts teardown
only after the crash callback finishes.

If stop arrives while output awaits delivery, ingress closes immediately. The
driver finishes delivery, then starts stop teardown instead of ordinary work.

### Adapter resource

The generic helper brackets one adapter binding. The outer integration owns the
host runtime and its event loop.

The semantic adapter resource is:

```ocaml
module Adapter : sig
  type ('output, 'error) binding
  type ('output, 'error) resource

  type 'output delivery = {
    output : 'output;
    reason : Driver.Delivery.reason;
  }

  val resource :
    pp_error:(Format.formatter -> 'error -> unit) ->
    acquire:(('output, 'error) binding, 'error) Eta.Effect.t ->
    release:(('output, 'error) binding -> (unit, 'error) Eta.Effect.t) ->
    deliver:
      (('output, 'error) binding ->
       'output delivery ->
       (unit, 'error) Eta.Effect.t) ->
    crash_detected:
      (('output, 'error) binding ->
       Failure.t ->
       (unit, 'error) Eta.Effect.t) ->
    ('output, 'error) resource
end
```

One adapter-specific error type covers all four operations. A concrete adapter
can use a precise variant when its operations have different failures.

The delivery effect owns snapshot reconciliation. It also performs any required
host-thread scheduling.

Eta Crux exposes no generic host scheduler. It receives no host handle, toolkit
context, or host-thread capability.

`Session_replacement` forces complete current-output delivery. The adapter does
not suppress this delivery because the snapshot compares equal.

Binding acquisition and release failures stay outside the root failure state.
Only committed-output delivery failure becomes `Adapter_delivery`.

A crash-notification failure becomes secondary `Crash_handler` evidence. Eta
Crux calls the built-in minimal reporter, then starts crash teardown.

### Hosted helper and control

The hosted helper owns the repetitive driver loop:

```ocaml
module Hosted : sig
  module Control : sig
    type t

    type replace_error =
      | Starting
      | Replacement_pending
      | Terminating
      | Closed

    type replace_outcome =
      | Replaced
      | Stopped
      | Crashed of Failure.t

    val request_stop : t -> unit

    val replace_serialized_session :
      t ->
      Serialized_session.candidate ->
      (replace_outcome, replace_error) Eta.Effect.t
  end

  val run :
    'output Driver.t ->
    adapter:(Control.t -> ('output, 'error) Adapter.resource) ->
    (Driver.terminal, 'error) Eta.Effect.t
end
```

`Hosted.run` creates its control before it constructs the adapter resource. The
adapter can capture the control when acquisition installs host event paths.

During acquisition, stop interrupts acquisition and settles the dormant root.
If acquisition wins the race, the resource bracket releases the binding.

Replacement during acquisition returns `Starting`. The caller retains its
candidate session.

If acquisition fails, the helper requests stop and replaces the pending `Start`.
It settles the dormant root, then returns the acquisition failure.

The control lane stores at most one replacement request. A second request returns
`Replacement_pending`.

The owner processes the accepted request after the active delivery fence. It
processes that request before the next application action.

Acceptance transfers candidate ownership to `Hosted`. Every accepted path either
installs or closes the candidate.

Caller interruption stops only that caller's wait. The accepted administration
transaction continues.

A successful request returns `Replaced` after output delivery and fence removal.
Stop returns `Stopped`, and crash returns `Crashed failure`.

Stop aborts a replacement whose candidate is not installed. The helper closes
the owned candidate and produces no replacement output.

Crash follows the same abort rule and keeps crash priority. An installed session
still follows the committed replacement-delivery fence.

### Event conversion and capacity

Eta Crux exposes no generic host-event converter. A concrete adapter converts
host values to exported-endpoint payloads or source items.

A direct callback invokes a typed local exported endpoint. Its nested result
keeps export availability, root `Full`, and `Ingress_closed` separate.

A host callback system used as a source installs its callback in the outer
producer effect. Successful installation reports source readiness.

Its returned producer effect drains any adapter-owned buffer into the typed
source emitter. The source adapter defines that buffer's capacity result.

Eta Crux does not collapse adapter capacity, root capacity, and ingress closure.

### Startup and teardown

The complete integration uses this order:

1. Start the host runtime and its scheduling path.
2. Create the root and driver. The root contains an unprocessed `Start`.
3. Create the hosted control and acquire the adapter binding.
4. Advance `Start`, deliver the first output, and start its post-commit batch.
5. Run the driver until stop or crash reaches final root settlement.
6. Close the hosted control and settle accepted control requests.
7. Release the adapter binding.
8. Stop the host runtime and its scheduling path.

Callbacks can race root teardown. They receive `Ingress_closed` after stop or
crash closes ingress.

The adapter binding remains live through root settlement. This lifetime permits
immediate crash notification and final host reconciliation.

Interruption of `Hosted.run` requests root stop. Cancellation-protected cleanup
awaits root settlement and releases the binding.

The outer Eta effect then preserves its original interruption. A root crash still
wins over a concurrent stop request.

Binding release failure does not change the settled root result. Eta finalizer
semantics fail the outer hosted effect with the release cause.

### Concrete host checks

A same-domain host runs its delivery effect inline. It retains the previous
snapshot and reconciles the new snapshot directly.

A foreign retained host posts one closure to its owner loop. That closure captures
all thread-affine handles and performs the complete snapshot reconciliation.

The Eta domain receives only the typed delivery result. Sliml satisfies this
shape with one `schedule_on_ui` call per output.

The recording fake implements the same adapter resource without a toolkit. It
records scheduling, reconciliation, token answers, control requests, and release.

The prototype covers foreign-loop delivery, stop during delivery, delivery
failure, successful replacement, and replacement abort.

### Ownership

Eta Crux core owns root advancement, root wake, delivery tokens, post-commit
start, session fences, crash latching, and terminal settlement.

The generic hosted helper owns the driver loop, adapter resource bracket, control
queue, delivery-error conversion, and callback sequencing.

A concrete adapter owns binding state, snapshot reconciliation, host-thread
scheduling, host event conversion, source buffers, and toolkit operations.

The outer integration owns host-runtime startup and shutdown. Language placement
does not change these ownership rules.

### Prototype evidence

The selected prototype is on branch `prototype/eta-crux-host-adapter` at commit
`14a77c83`:

- [prototype](https://github.com/ribelo/eta/tree/14a77c83/.scratch/prototypes/eta-crux-host-adapter)
- [design](https://github.com/ribelo/eta/blob/14a77c83/.scratch/prototypes/eta-crux-host-adapter/DESIGN.md)
- [results](https://github.com/ribelo/eta/blob/14a77c83/.scratch/prototypes/eta-crux-host-adapter/RESULTS.md)

The prototype compiles in the OxCaml Nix shell.

### Rejected alternatives

Eta Crux does not expose host handles, a renderer, a host value model, a generic
event converter, or a generic host-thread scheduler.

It does not make each concrete adapter reproduce root advancement and terminal
ordering. It also does not hide stale-endpoint advancement or committed output.

It does not merge adapter buffer capacity with root capacity. It does not cancel
an accepted session replacement because its requesting caller stops waiting.
