# Timer and observer edge protocols

Date: 2026-08-06

## Scope

This report answers the
[Timer and observer edge protocols](../../../docs/wayfinder/eta-signal-execution-model/issues/10-timer-and-observer-edges.md)
ticket.

The report models post-commit timer, observer, cleanup, and stream work.
It also executes the selected protocol through the private `Execution.run` seam
and an Eta/Eio runtime.

The state-model probe is in
[`edge-protocol-probe/`](edge-protocol-probe/).
The integrated probe is in
[`edge-seam-probe/`](edge-seam-probe/).
Both probes are throwaway code and do not change the production Signal engine.

## Current result

One private post-commit driver with opaque edge batches passes the applicable
behavior, affected-work, allocation, and wall-time gates.

The state-model probe isolates the edge protocols.
The integrated probe composes the same model with the issue 09 execution seam.
The state-model probe supplies the timer-ballast and exact affected-work checks.

The synchronous kernel publishes values, topology, observer cursors, and edge
work under `Execution.run`.
The post-commit driver then owns every claim and terminal transition.

Timer starts, timer stops, finish hooks, observer callbacks, and stream
publication run outside the graph lane.
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

The driver obtains the active runtime through the same interpreter context as
`Execution.run`.
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

The selected protocol uses this order:

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
The driver still runs these operations on the owner domain.

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

The state-model executable measures the isolated synchronous state machines.
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

The state-model and reference rows do not have the same adapter boundary.
They cannot close the issue 04 acceptance rows.

The numbers rank state representations only.

Complete samples are in
[`results.csv`](edge-protocol-probe/results.csv).
Process medians are in
[`summary.csv`](edge-protocol-probe/summary.csv).

## Integrated Eta/Eio evidence

The integrated probe copies the selected issue 09 `Execution.run` driver.
The driver gets the active runtime from `Eta.Spi.Expert`.
It uses the production graph-lane module and the Eio runtime contract.

Observer callbacks are Eta effects.
The delivery finalizer settles the exact token under `Execution.run`.
Typed failures, defects, and interruptions keep unacknowledged delivery
pending.

Timer starts use `Eta.Spi.daemon`.
The daemon gets its cancellation handle from the active runtime contract.
Timer creation stores the real runtime identity.
Reconciliation uses `Runtime_contract.same_runtime` before it claims work.

The integrated checks cover these observations:

| Observation | Result |
|---|---|
| Typed callback failure | Eta returns `Cause.Fail`, and the exact token stays pending. |
| Callback defect | Eta returns `Cause.Die`, and the exact token stays pending. |
| Callback interruption | Eio interruption escapes, and the protected finalizer restores the exact token. |
| Callback retry | A later stabilization acknowledges the retained token. |
| Disposal | The finish hook runs outside the lane and runs once. |
| Runtime provenance | A foreign Eta runtime cannot register, stabilize, or wake a timer. |
| Timer initialization | Stabilization initializes an observer without a timer wake. |
| Registration failure | Start failure and post-install cancellation remove observer demand and daemon state. |
| Start and stop retry | Injected start and stop defects keep exact retry state. |
| Daemon failure | A failed daemon loop requeues live demand, and stabilization restarts it. |
| Timer generation fence | Demand loss rejects a late wake before stop retry. |
| Demand reentry | Demand that returns across a fenced stop starts a new generation. |
| Immediate disposal | A timer reaches `Inactive` without exposing `Starting`. |
| Timer lifecycle | One Eta daemon starts, wakes, publishes through stabilization, and stops. |
| Lane release | Observer callbacks, finish hooks, timer starts, and timer stops run outside the lane. |

The command runs these checks:

```sh
nix develop -c \
  .scratch/research/eta-signal-execution-model/edge-seam-probe/_build/default/probe.exe \
  --check
```

## Matched edge rows

The integrated harness uses the three pinned-reference operation tapes.
Setup, final state checks, and teardown stay outside each measured operation.

| Row | Smallest graph | One measured operation |
|---|---|---|
| Observer failure and retry | one source and one observer | set, failed stabilization, successful retry |
| Observer disposal | one source and one observer | register, dispose |
| Timer cycle | one interval timer and one observer | start, wake, stabilize, dispose, stop |

The release run used three fresh candidate and reference process pairs.
Each process reported nine samples.
The candidate and reference calibrated their operation counts independently.

| Row | Candidate words | Reference words | Allocation ratio | Candidate wall-time range | Reference wall-time range | Largest wall ratio |
|---|---:|---:|---:|---:|---:|---:|
| Observer failure and retry | 2,752 | 10,504 | 0.262 | 3,763.65-3,821.79 ns | 12,230.45-12,300.55 ns | 0.311 |
| Observer disposal | 903 | 6,188 | 0.146 | 1,288.26-1,316.10 ns | 8,162.47-8,247.79 ns | 0.161 |
| Timer cycle | 7,005 | 21,185 | 0.331 | 9,979.46-10,059.38 ns | 27,395.11-27,507.48 ns | 0.366 |

All allocation rows stay below the pinned reference.
All candidate wall-time medians stay below the reference in all three pairs.
Thus, all three rows pass the issue 04 Eta-only edge gates.

Complete samples are in
[`results.csv`](edge-seam-probe/results.csv).
Process medians are in
[`summary.csv`](edge-seam-probe/summary.csv).

## Limits

The integrated probe uses a scalar projection instead of the complete graph
kernel.
It does not construct dynamic topology or a multi-observer topological plan.
Issues 08 and 11 own those integrated paths.

The state-model probe uses integer runtime identities.
The integrated probe uses `Runtime_contract.same_runtime`.

The state-model probe injects timer wakes.
The integrated probe uses an Eta daemon and the same deterministic Eio clock as
the reference.

The reference disposal operation includes observer registration.
The state-model disposal operation also publishes an observer value.
The integrated candidate registers graph demand and uses the same
register-and-dispose tape as the reference.

The stream row checks send, drop, and acknowledgement only.
The existing `eta_signal_stream` tests remain authoritative for queue closure
and cross-domain consumption.

## Decision

Use one opaque post-commit driver.

Keep timer generations, runtime provenance, observer cursors, cleanup
aggregation, and stream acknowledgement inside this driver.

Run user effects outside the graph lane.
Linearize every claim and terminal result under the lane.

Keep the current Eta runtime interface.
Add no runtime primitive and expose no edge cursor.
