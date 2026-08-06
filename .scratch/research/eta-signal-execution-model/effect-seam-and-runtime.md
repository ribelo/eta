# Effect seam and Eta runtime

Date: 2026-08-06

## Scope

This report answers the
[Effect seam and Eta runtime](../../../docs/wayfinder/eta-signal-execution-model/issues/09-effect-seam-and-runtime.md)
ticket.

The report selects the private seam between the synchronous Signal kernel and
Eta interpretation. It also defines runtime ownership and cancellation before
publication.

Observer callbacks, timer lifecycle, and disposal remain with issue 10.

The durable evidence is in
[`effect-seam-probe/`](effect-seam-probe/).
The probe is throwaway code and does not change the production Signal engine.

## Answer

Use one private `Execution.run` operation around synchronous kernel work.

The operation obtains the current Eta runtime when Eta interprets the effect. It
acquires one graph lane and supplies one cancellation checkpoint to the kernel.

The kernel calls the checkpoint immediately before publication. Cancellation at
this fence uses the normal sparse rollback path.

The execution module preserves Eta typed failures, defects, and interruption as
different outcomes. It also owns same-fiber reentry and owner-domain checks.

Keep post-commit claims opaque. The execution module can consume claims through
private steps, but Signal adapters must not own claim order or retry rules.

Do not add a general Eta runtime primitive. The existing runtime contract
already supplies every required operation.

## Selected interface

Production names can differ. The private interface has this shape:

```ocaml
module Execution : sig
  type t

  val run :
    t ->
    ((unit -> unit) -> ('a, 'error) result) ->
    ('a, 'error) Eta.Effect.t
end
```

The callback is synchronous. It cannot yield, retain lane access, or run a user
effect.

The callback receives a cancellation checkpoint. A stabilization calls this
function after fallible planning and immediately before publication.

The execution module hides these items:

- the active `Runtime_contract.t`
- the graph lane and its access token
- the waiter queue
- the owner fiber identity
- the fiber-local reentry depth
- cancellation cleanup
- typed exit conversion

The raw kernel does not contain an Eta Effect or Eio type.

## Operation protocol

`Execution.run` uses this order:

1. Check the graph owner domain and the worker context.
2. Get the current runtime contract.
3. Reenter when the current fiber already owns the graph lane.
4. Otherwise, acquire the graph lane or wait in its FIFO queue.
5. Run the synchronous kernel callback after the grant.
6. Release the graph lane in cancellation-protected cleanup.
7. Wake the next live waiter after the queue state commits.

A cancellation while the caller waits removes its logical waiter. The kernel
callback does not run.

A cancellation during planning reaches the checkpoint before publication. The
kernel restores values and topology, and retains source admission for retry.

Publication clears the rollback journal. Later observer or timer failures cannot
use the rollback path.

## Typed outcomes

The execution module maps outcomes as follows:

| Kernel or runtime outcome | Eta outcome |
|---|---|
| `Ok value` | `Exit.Ok value` |
| `Error graph_error` | `Cause.Fail graph_error` |
| Ordinary exception | `Cause.Die` with its backtrace |
| Runtime cancellation | Eta interruption |

The probe checks a typed graph failure and an injected defect separately. It
also checks actual Eio cancellation before publication.

## Reentry

The owner fiber identity is the reentry key. Nested Eta runtimes on one host
fiber preserve that identity.

A nested operation from the owner fiber uses the current lane access. It does
not wait or release the lane.

A forked child has another fiber identity. It waits behind the owner.

The graph still owns semantic reentry checks. For example, nested stabilization
returns `Reentrant_stabilization` before it changes rollback state.

## Runtime ownership

The graph owns one OCaml domain. Every graph operation checks this domain before
it mutates lane or graph state.

The Eta runtime owns these operations:

- cancellation checks
- cancellation protection
- one-shot promises and resolvers
- fiber identity
- fiber-local bindings
- monotonic time
- daemon ownership

The Signal package does not depend on Eio. A synchronous runtime and the Eio
runtime both satisfy `Runtime_contract.RUNTIME`.

Timer nodes will retain their creating runtime identity. Issue 10 must use
`Runtime_contract.same_runtime` for timer provenance.

## Runtime primitive decision

Signal does not need a new Eta runtime primitive.

The selected module uses these existing runtime operations:

- `check`
- `protect`
- `create_promise`
- `await_promise`
- `resolve_promise`
- `cancellation_reason`
- `current_fiber_id`
- `local_with_binding`

The motivating runtime invariant already belongs to `resolve_promise`.

Queue state must commit before wake notification. Notification must not run Eta
code on the resolving domain.

A cancelled waiter can still have its promise resolved. Resolution makes a live
waiter runnable before it returns.

This invariant supports Signal, Semaphore, Queue, Pool, and other Eta-owned
wait queues. A new Signal-specific primitive duplicates this contract.

## Design It Twice

Four designs were compared.

### A. Minimal serialized execution

This design exposes only `run`. It hides runtime selection, lane ownership,
reentry, cancellation, and cause conversion.

This design has the most depth and the best locality. It is selected.

### B. Semantic operation facade

This design exposes private `set`, `update_effect`, `stabilize`, `read`,
`dispose`, `stats`, and timer operations.

These functions repeat the public Signal operation list. The module adds little
leverage and becomes a pass-through facade.

Keep semantic operations in the public adapter. Use `Execution.run` for their
synchronous graph sections.

### C. Fused common operation

This design exposes `set_and_stabilize` for the common benchmark pair.

The operation removes the explicit stabilization boundary and cannot replace
independent source admissions. It optimizes one caller shape instead of hiding a
general invariant.

Reject this interface. Keep public `Var.set` and `stabilize` separate.

### D. Mirrored runtime port

This design copies promises, protection, fiber identity, locals, cancellation,
and provenance into a Signal-specific port.

The port mirrors `Runtime_contract`. It adds an adapter without adding behavior.

Reject the mirror. Keep the current runtime contract behind the private
execution module.

## Private claims versus edge cursors

Issue 05 deferred two post-commit seam shapes.

The deep-driver shape returns or consumes an opaque claim. The driver owns the
legal claim and acknowledgement order.

The cursor shape exposes `next_claim` and `acknowledge` as separate serialized
operations. Its caller must know ordering, retry, and stale-claim rules.

The probe uses one synthetic claim with no external effect. This row measures
seam crossings only.

| Shape | Median allocation | Median wall time |
|---|---:|---:|
| Opaque claim inside the driver | 106 words | 118.50-118.57 ns |
| Explicit claim cursor | 346 words | 405.84-411.54 ns |

The explicit cursor adds 240 words. Its median wall time is 3.42 to 3.47 times
the opaque-claim row.

This result does not measure a user callback. Issue 10 must release the lane
before callback execution and charge those crossings to observer delivery.

Keep claim choreography private. Do not publish the cursor as the adapter
interface.

## Behavior evidence

One command runs all semantic checks:

```sh
nix develop -c \
  .scratch/research/eta-signal-execution-model/effect-seam-probe/_build/default/probe.exe \
  --check
```

The checks cover these observations:

| Observation | Result |
|---|---|
| Typed graph failure | The effect returns `Cause.Fail`. |
| Defect | The effect returns `Cause.Die`. |
| Same-fiber nested operation | The nested body runs once without waiting. |
| Injected pre-publication failure | The committed value stays old, and retry publishes the admitted value. |
| Eio cancellation before publication | The checkpoint triggers rollback, and retry publishes the admitted value. |
| Queued cancellation | The cancelled body never runs. |
| Waiter cleanup | The waiter count returns to zero, and the cancellation count increases once. |
| Later use | A later operation acquires the lane. |
| Wrong domain | The operation fails before its body runs. |

The current production lane tests remain authoritative for grant-resolution
failure, generated cancellation races, forked-child waiting, and acquisition on
the owner domain.

## Measurement protocol

The release build used the required OxCaml Nix shell. Each workload ran on CPU
2.

Each process calibrated from one operation. It doubled the count until the batch
took 0.5 seconds or reached 16,777,216 operations.

Each process reported nine samples. The run used three fresh processes for each
row. The tables contain each process median.

Allocation uses this formula:

```text
minor words + major words - promoted words
```

The scalar adapter rows use the same raw kernel. One operation sets one source
and stabilizes one depth-1, depth-10, or depth-100 chain.

The prototype kernel is a scalar projection of the selected representation. It
uses in-place values, an immediate sparse undo journal, O(1) commit, and a
pre-publication checkpoint.

The probe excludes dynamic topology because issue 08 already proved that its
machinery bypasses static passes.

Complete samples are in
[`results.csv`](effect-seam-probe/results.csv). Process medians are in
[`summary.csv`](effect-seam-probe/summary.csv).

## Adapter allocation

The table shows allocation for every process. The values were identical across
depths, apart from measurement residue.

| Layer | Total words | Adapter delta | Ceiling | Result |
|---|---:|---:|---:|---|
| Raw scalar kernel | 0 | — | fewer than 100 | Pass |
| One prebuilt Effect step | 10 | 10 | 10 | Pass |
| Private execution driver | 106 | 96 | 169 | Pass |
| Separate public set and stabilization | 204 | 98 | 1,083 | Pass |
| Eio public operation | 487 | 283 | 1,174 | Pass |

No adapter allocation increases with graph depth.

The driver row includes the cancellation checkpoint. The checkpoint does not
require a second Eta custom leaf.

## Adapter wall time

These are the process median ranges:

| Layer | Depth 1 | Depth 10 | Depth 100 |
|---|---:|---:|---:|
| Raw | 4.34-4.37 ns | 12.02-12.11 ns | 99.01-100.35 ns |
| Effect | 7.70-8.04 ns | 14.87-14.99 ns | 102.78-103.18 ns |
| Driver sync | 116.01-117.37 ns | 125.47-132.00 ns | 221.25-227.61 ns |
| Public sync | 243.71-256.61 ns | 257.79-286.05 ns | 357.40-360.26 ns |
| Public Eio | 652.80-662.98 ns | 673.66-674.96 ns | 766.16-771.22 ns |

Issue 04 gives allocation ceilings for these adapters. Its wall-time acceptance
rule compares complete matched operations in issue 11.

## Queued-cancellation edge row

The edge workload uses one holder and one cancelled contender. The contender
queues before cancellation and never enters its operation body.

The candidate graph has a driver and a depth-1 scalar kernel. The reference
graph has a source, one map, and one observer.

| Pair | Candidate operations | Reference operations | Candidate words | Reference words | Candidate ns | Reference ns | Wall ratio |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 262,144 | 65,536 | 1,509 | 6,911 | 2,237.04 | 8,829.51 | 0.253 |
| 2 | 262,144 | 65,536 | 1,509 | 6,911 | 2,174.51 | 8,688.78 | 0.250 |
| 3 | 262,144 | 65,536 | 1,509 | 6,911 | 2,178.71 | 8,707.78 | 0.250 |

The candidate allocation is 21.8% of the pinned reference. Its wall time is less
than the reference in all three pairs.

This row passes the issue 04 Eta-only edge gate.

## Limits

The scalar probe does not repeat generic value, dynamic topology, or keyed
measurements. Issues 08 and 16 own those representations.

The synthetic claim row does not execute a user callback. It compares only the
private claim and cursor seam costs.

The probe does not cover observer failure, timer start, timer wake, timer stop,
or disposal. Issue 10 owns those rows.

The wrong-domain check uses one throwaway OCaml domain. Production code must use
the repository threading library for application domain work.

## Decision

Use one private serialized execution driver with one synchronous callback and
one pre-publication cancellation checkpoint.

Keep runtime selection, lane ownership, same-fiber reentry, waiter cancellation,
and Eta cause conversion in that module.

Keep claim and acknowledgement choreography private. Do not expose explicit edge
cursors to Signal adapters.

Use the existing Eta runtime contract. Add no general Eta runtime primitive.
