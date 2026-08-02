# Deterministic advancement transaction

Type: grilling
Status: resolved
Blocked by: 05

## Question

What does one deterministic advancement do, in what order, and where is its
commit boundary?

Decide:

- whether an advancement processes one action or a bounded available batch.
- when pending input changes enter the graph.
- model transition and commit order across independent state machines.
- `eta_signal` stabilization and rollback behavior.
- dynamic activation and deactivation order.
- output publication and adapter notification order.
- when staged effects start.
- how actions injected during any phase are deferred.
- wake conditions for hosted execution, timers, shutdown, and external sources.
- the exact result returned by explicit advancement.

The hosted loop and all test drivers must use this same transaction. The answer
must make partial state and reentrant advancement impossible or explicitly
typed as an error.

## Answer

### Public semantic result

One advancement processes at most one queued message. Its semantic result is:

```ocaml
module Post_commit : sig
  type t
  type start_error = Already_started

  val start : t -> (unit, start_error) Eta.Effect.t
end

type 'output outcome =
  | Idle
  | Rejected of delivery_error
  | Committed of {
      output : 'output;
      post_commit : Post_commit.t;
    }
  | Stopped of {
      post_commit : Post_commit.t;
    }
  | Failed of Failure.t

type advance_error =
  | Already_advancing
  | Awaiting_post_commit
  | Closed

val advance :
  'output Root.t -> ('output outcome, advance_error) result
```

This is a semantic signature. [OCaml API syntax and ergonomics](14-ocaml-api-ergonomics.md)
owns final names and nesting. [Failure, defect, and crash boundary](11-failure-boundary.md)
defines `Failure.t` and the root state after `Failed`.

Every successful `Start` or application message returns the complete committed
root output, even when it compares equal to the previous output. Observation
policy does not change the transaction result.

### Queue and ingress

External values enter application state only through typed endpoint messages.
Eta Crux exposes no separate mutable root-input path.

Each advancement removes exactly one message. Hidden queue batching is not an
optimization because it changes output and effect timing. Applications can use
an explicit batch action when several domain changes form one transaction.

Messages arriving during advancement append to the queue. They never join the
active transaction. A transition from an empty queue to a nonempty queue emits
one driver wake. Further messages need no additional wake while work remains.

`Root.create` creates the private runtime and queues one internal `Start`
message. The first advancement instantiates, stabilizes, and commits the initial
graph through the normal transaction.

### Advancement phases

An advancement from `Ready` follows this order:

1. Set the root phase to `Advancing` and remove one message.
2. For an application message, validate the target endpoint incarnation.
3. Run its synchronous transition against committed input and model snapshots.
4. Stage its returned model and source-owned Eta effect.
5. Run the pure computation phase of private `eta_signal` stabilization.
6. Preflight dynamic structure and compute lifecycle changes.
7. Compute the complete typed root output snapshot.
8. Commit model, graph, scopes, lifecycle changes, output, and effect eligibility
   as one atomic state change.
9. Create a post-commit batch and enter `Awaiting_post_commit`.
10. Return `Committed` with the output and batch.

`Start` skips endpoint validation and transition. It stages initial graph
construction before the same stabilization and commit phases. `Stop` follows a
separate disposal branch described below.

Pure description callbacks can run during stabilization. Adapter callbacks,
lifecycle hook bodies, and returned Eta effects never run inside advancement.

Structural commit detaches removed scopes before attaching added scopes. No
observer can access the intermediate structure. The output belongs to the fully
committed structure.

### Rejection and failure

A stale endpoint message is consumed and returns `Rejected Stale_endpoint`.
No transition or stabilization runs, and the root returns to `Ready`.

A transition exception, stabilization failure, or structural preflight failure
rolls back every staged change. The message remains consumed. The advancement
returns `Failed`, publishes no output, and creates no post-commit batch.

Eta Crux never retries a failed message automatically. A caller can retry by
sending another message after the failure policy permits further advancement.

A call to `advance` during `Advancing` returns `Already_advancing`. A call while
a committed batch remains unstarted returns `Awaiting_post_commit`. Neither call
touches the queue.

An empty queue returns `Idle` without stabilization or output delivery.

### Post-commit batch

Every commit returns a batch, including a commit with no lifecycle or transition
work. Starting an empty batch acknowledges output delivery.

The driver first delivers the committed output to its adapter. It then starts
the batch. Batch start is at most once.

Admission is cancellation-protected and atomic. It registers every eligible
activation program and transition effect behind closed release gates. No new
work body starts during registration.

After registration, batch start follows this order:

1. Request cancellation of removed scope subtrees.
2. Release activation lifecycle programs.
3. Wait for each new source opening barrier.
4. Release the transition effect.

Each removed subtree uses `Supervisor.Scope.request_cancel`. The next phase
starts only after every request operation returns. It does not wait for removed
subtree settlement.

Ordinary lifecycle programs have no opening barrier. A source activation opens
its item-admission path before it reports readiness. Its long-lived producer
effect starts after successful opening.

New source openings run concurrently. A typed opening failure first enqueues its
terminal action and then resolves its barrier. The transition effect starts only
after every opening reports readiness or a typed opening failure.

The outer source-opening effect returns after it installs the admission path.
Unbounded source work belongs in the returned producer effect. [Long-lived
sources and subscriptions](08-subscriptions-and-sources.md) owns this protocol.

Work bodies can overlap after release. Effects from earlier advancements can
remain active while the driver processes later messages. The
[Eta supervised work substrate](19-eta-supervised-work-substrate.md) owns the
request and settlement split.

A transition effect whose source scope was disposed by the same commit is not
admitted. Cancellation of an ordinary removed scope does not delay activation
or transition work until cleanup completion. The closing scope remains tracked.

The root returns to `Ready` only after complete batch admission. A second start
returns `Already_started`. Exact cancellation and finalizer ordering belong to
[Dynamic lifetime and work ownership](07-dynamic-lifetime-ownership.md).
[Failure, defect, and crash boundary](11-failure-boundary.md) defines adapter
delivery failure before batch start.

### Hosted execution

After starting a batch, the hosted driver calls `advance` again. It repeats this
sequence until `Idle`, then sleeps until the next empty-to-nonempty wake.

Timers and external sources wake the driver by sending endpoint messages. Tests
use the same `advance` and batch-start operations without another transaction
model.

A shutdown request closes message admission and discards queued application
messages. It also replaces a pending `Start`, then places an internal `Stop` as
the next message. The stop advancement atomically disposes the graph and returns
`Stopped` with its final post-commit batch. Starting that batch interrupts and
awaits the complete root work tree. The root enters `Closed` only after all work
and finalizers settle.

Calls to `advance` after final batch completion return `Closed`.

### Rejected alternatives

Eta Crux does not drain an implicit queue batch or use a configurable message
limit. Transport packet grouping and host timing therefore cannot change one
advancement's meaning.

Eta Crux does not call adapters or user effects during graph mutation. It does
not allow another advancement before the previous output and post-commit work
receive their ordering point.
