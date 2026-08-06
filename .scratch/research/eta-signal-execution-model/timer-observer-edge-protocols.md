# Timer and observer edge protocols

Date: 2026-08-06

## Scope

This report records partial evidence for the
[Timer and observer edge protocols](../../../docs/wayfinder/eta-signal-execution-model/issues/10-timer-and-observer-edges.md)
ticket.

The report models post-commit timer, observer, cleanup, and stream work.
It does not execute the private `Execution.run` seam from issue 09.

The durable probe is in
[`edge-protocol-probe/`](edge-protocol-probe/).
The probe is throwaway code and does not change the production Signal engine.

## Current result

The state model supports one private post-commit driver with opaque edge
batches.

The following paragraphs describe the candidate protocol.
They do not describe an executed Eta seam.

The synchronous kernel publishes values, topology, observer cursors, and edge
work under `Execution.run`.
The post-commit driver then owns every claim and terminal transition.

Timer operations, finish hooks, observer callbacks, and stream publication run
outside the graph lane.
The driver enters the lane only to claim work or publish a terminal result.

Do not add an edge cursor to the package adapter.
Do not add timer, observer, or stream ports to the raw kernel.

## Candidate interface

Production names can differ.
The private composition has this shape:

```ocaml
module Post_commit : sig
  type t

  val run :
    t ->
    execution:Execution.t ->
    (unit, stabilize_error) Eta.Effect.t
end
```

`t` contains an opaque batch.
Only the kernel and the post-commit driver can construct or inspect this batch.

The public adapter receives only the final Eta effect.
It cannot select work order, retain a claim, or acknowledge a stale claim.

The candidate obtains the active runtime through the same interpreter context
as `Execution.run`.
It does not accept an independent runtime argument.

The `Execution.run` interface stays unchanged:

```ocaml
val run :
  Execution.t ->
  ((unit -> unit) -> ('a, 'error) result) ->
  ('a, 'error) Eta.Effect.t
```

The kernel callback stays synchronous.
The cancellation checkpoint stays immediately before publication.

## Phase order

The candidate protocol uses this order:

1. The kernel completes pure planning.
2. The kernel calls the cancellation checkpoint.
3. The kernel publishes one committed snapshot and its opaque edge batch.
4. Structural cleanup releases retired slots and topology capsules.
5. The driver claims queued timer mismatches.
6. The driver runs timer starts and stops outside the lane.
7. The driver settles timer results under the lane.
8. The driver runs every finish hook outside the lane.
9. The driver delivers observer events in the frozen plan.
10. The driver returns the graph to idle under the lane.

Structural cleanup is mandatory internal work.
It runs before every effectful edge.

Timer reconciliation runs before finish hooks.
This order matches the current disposal behavior and gives finish hooks a settled
timer boundary.

Observer callbacks run only after all required cleanup succeeds.
A cleanup failure leaves observer delivery pending.

## Observer protocol

The commit batch contains one event for each candidate observer.
The event order comes from the final topological plan.

The driver claims one event under the lane.
The claim changes the cursor from pending to running.

The driver then releases the lane and runs the callback effect.
A protected finalizer settles the exact token under the lane.

Success acknowledges the token.
A typed failure, defect, or interruption releases an unacknowledged token to
pending.

Delivery stops after the first callback failure.
Earlier acknowledged events remain acknowledged.
The active failed suffix remains pending.

A later stabilization coalesces each pending event against the last delivered
value.
It plans the retry from the latest committed topology.

Disposal and invalidation use the same cursor owner.
They clear pending work and make a running-token finalizer a no-op.

A callback that is already running is not cancelled by disposal.
Its result cannot restore a disposed cursor.

The sealed stream acknowledgement uses the same token.
Acknowledgement inside a callback wins before later failure release.

## Timer protocol

Each timer stores its creating runtime identity and one generation.
The queued mismatch list contains only timers whose effective demand differs
from their daemon state.

The driver checks `Runtime_contract.same_runtime` before it claims a mismatch.
A mismatch remains queued after `Runtime_mismatch`.

A zero-to-one demand transition queues one start.
Other positive demand changes queue nothing.

A one-to-zero transition increments the generation before cancellation.
The old daemon is stale before its cancellation function runs.

A daemon wake contains the timer handle and generation.
One `Execution.run` call accepts a matching wake and admits source work.

A stale wake does nothing.
A wake never calls `stabilize`.

Timer starts and cancellation functions run outside the lane.
The candidate must still run these operations on the owner domain.

A failed start leaves no installed daemon and requeues the mismatch.
The candidate must keep the committed snapshot after a failed stop.
It must also requeue cleanup.

The driver attempts every action and every finish hook.
It aggregates failures in invocation order.

## Stream bridge

The stream bridge remains outside the scalar kernel.
It consumes the sealed observer-delivery capability.

One offered update has one sent-or-dropped result.
It also has one acknowledgement.

The candidate puts queue publication and acknowledgement in one
cancellation-protected callback region.
Interruption cannot split these operations.

A full queue drops the newest update.
The synchronous drop hook can fail, but the bridge still acknowledges the drop.

The state model records one drop-hook failure.
The production bridge must log the documented defect and must not retry that
hook.

## Design It Twice

Three designs were compared.

### A. Opaque post-commit driver

This design hides batches, claims, timer generations, cursors, and
acknowledgements.

The driver owns the complete race and retry protocol.
This design has the deepest interface and is selected.

### B. Explicit edge cursors

This design exposes `next_delivery`, `next_timer_action`, and acknowledgement
operations.

The package adapter must reproduce ordering, stale-token, retry, and failure
rules.
It also adds at least one lane crossing for each read and acknowledgement.

Issue 09 measured this control.
It allocated 346 words instead of 106 words for the opaque claim.
Its wall time was 3.42 to 3.47 times the opaque claim.

Reject this design.

### C. Injected execution ports

This design gives the raw kernel separate clock, serialization, lifecycle, and
delivery ports.

The ports split timer provenance, cleanup precedence, and cursor ownership.
They also put Eta effect concepts into the raw-kernel boundary.

Reject this design.

## State-model evidence

Run the checks with this command:

```sh
nix develop -c \
  .scratch/research/eta-signal-execution-model/edge-protocol-probe/_build/default/probe.exe \
  --check
```

The checks cover these observations:

| Observation | Result |
|---|---|
| Supplied observer order | Delivery preserves the supplied dependency-first plan. |
| Callback failure | The exact token returns to pending. |
| Callback retry | The callback succeeds on the next post-commit run. |
| Callback disposal | Disposal wins and finish registers once. |
| Acknowledgement then failure | Failure cannot restore the acknowledged token. |
| Callback interruption | The exact unacknowledged token returns to pending. |
| Failed timer start | The mismatch stays queued and retry starts one daemon. |
| Timer generation fence | A late wake after demand loss does nothing. |
| Runtime provenance | A foreign runtime fails before it claims timer work. |
| Cleanup aggregation | Timer and hook failures stay ordered, and observer delivery stays pending. |
| Stream drop | The raising drop hook cannot prevent acknowledgement. |
| Stream interruption | Published queue work stays acknowledged. |
| Timer economics | 1, 32, and 1,024 mismatches produce exact claim counts. |
| Timer ballast | The registry has 100,000 inactive timers, while claims use only the mismatch queue. |
| Lane release | User callbacks and timer functions never run under the lane. |

The existing public and model tests remain the full behavior oracle.
The prototype isolates only a synchronous edge-state model.

The model collapses typed failures, defects, and interruption into injected
exceptions.
It checks their shared cursor result, not Eta cause classification.

## Measurement protocol

The release build used the OxCaml Nix shell.
Each process ran on CPU 2.

Each process doubled its operation count until the batch reached 0.5 seconds.
The maximum count was 16,777,216 operations.

Each row used nine samples in three fresh processes.
Allocation uses this formula:

```text
minor words + major words - promoted words
```

The reference executable uses the public engine at commit `d04d6e2b`.
Production Signal sources have no change from that commit to this branch.

The candidate executable measures the isolated synchronous state machines.
Issue 09 already measures the selected Eta execution adapter.

## Component diagnostics

The table shows the three process medians.

| Candidate operation | Allocated words | Wall-time range |
|---|---:|---:|
| Successful observer delivery | 58 | 23.88-24.02 ns |
| Observer failure and retry | 105 | 51.73-53.31 ns |
| Observer disposal and skipped event | 58 | 25.42-25.48 ns |
| Stream send and acknowledgement | 79 | 38.91-38.96 ns |
| Timer start, wake, and stop cycle | 83 | 43.94-45.83 ns |

The pinned-reference rows use related complete public operations:

| Reference operation | Allocated words | Wall-time range |
|---|---:|---:|
| Observer failure and retry | 10,504 | 12,252.27-12,438.36 ns |
| Observer registration and disposal | 6,188 | 8,150.92-8,250.84 ns |
| Timer start, wake, and stop cycle | 21,185 | 27,771.85-27,865.59 ns |

The timer cycle reaches all three timer edges in one operation.

The candidate and reference rows do not have the same adapter boundary.
They cannot close the issue 04 acceptance rows.

The numbers rank state representations only.
The next prototype must use the actual `Execution.run` and Eta/Eio adapter.
It must run the same operation tape on both sides.

Complete samples are in
[`results.csv`](edge-protocol-probe/results.csv).
Process medians are in
[`summary.csv`](edge-protocol-probe/summary.csv).

## Limits

The prototype does not implement `Execution.run`, Eta effects, graph topology,
or observer-plan construction.
Issues 08 and 11 own those integrated paths.

The prototype uses integer runtime identities.
Production code must use `Runtime_contract.same_runtime`.

The prototype injects timer wakes.
It does not implement a real clock or daemon scheduler.

The reference disposal operation includes observer registration.
The candidate disposal operation also creates, publishes, and disposes one
observer.

The stream row checks send, drop, and acknowledgement only.
The existing `eta_signal_stream` tests remain authoritative for queue closure
and cross-domain consumption.

## Provisional direction

Retain one opaque post-commit driver as the next candidate.

Keep timer generations, runtime provenance, observer cursors, cleanup
aggregation, and stream acknowledgement inside this driver.

Run user effects outside the graph lane.
Linearize every claim and terminal result under the lane.

Keep the current Eta runtime interface.
Add no runtime primitive and expose no edge cursor.

Ticket 10 remains open until an Eta/Eio prototype proves this composition.
That prototype must close the matched failure, disposal, and timer rows.
