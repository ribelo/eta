# Node identity and index lifecycle

Date: 2026-08-06

## Scope

This report answers the
[Node identity and index lifecycle](../../../docs/wayfinder/eta-signal-execution-model/issues/15-node-identity-and-index-lifecycle.md)
ticket.

The report selects the private identity, reuse, cleanup, and rollback model for
dense node slots.

The model extends the index journal from
[Failure and rollback model](failure-and-rollback-model.md).
It keeps the direct static kernel from
[Value-propagation kernel prototype](value-propagation-kernel.md).

The durable evidence is in
[`node-lifecycle-probe/`](node-lifecycle-probe/).
The probe is throwaway code and does not change the production Signal engine.

Dynamic edges, scopes, keyed reconciliation, Effect, Eio, observers, and timers
remain outside this prototype.

## Answer

Select candidate B, which uses a free list, integer generations, and one
quarantine for each active pass.

Long-lived handles contain `(slot, generation)`.
A lookup compares both integers before it returns a node.

Active rollback journals contain slot integers without generations.
The quarantine prevents reuse of a retired slot during the active pass.

Thus each active slot integer identifies one node incarnation for that complete
pass.

Commit sets the active journal length to zero.
Its source contains no journal loop or node loop.

The arena enforces `Idle`, `Active`, and `Cleanup_pending`.
Committed lifecycle actions remain fenced until cleanup returns the arena to
`Idle`.

The next pass overwrites the stale prefix from index zero before that prefix
becomes active.

Cleanup visits only lifecycle entries from the committed pass.
Rollback visits only active topology actions and value-journal entries.

`begin_pass` checks pass identity exhaustion before any state change.
Signal maps this exhaustion to `` `Counter_overflow``.

The public Signal execution seam stays unchanged:

```ocaml
val set : t -> 'a var -> 'a -> unit
val stabilize : t -> (stabilization, error) result
```

## Binding behavior and observation boundary

The binding oracle is
[`binding-signal-behavior.md`](binding-signal-behavior.md).
Issue 15 inherits the rows below.

| Row | Inherited behavior | Exact public observation boundary |
|---|---|---|
| SB09 | Publication precedes observer delivery and timer cleanup. | Public reads and callbacks during one operation |
| SB10 | Pre-publication failure preserves committed values and topology. Post-publication failure does not roll back publication. | Observer reads, branch identity, failure exit, and retry |
| SB11 | Monotonic counters fail instead of wrapping. | A documented exception or typed Effect exit |
| SB12 | Branch replacement invalidates the replaced scope. Failure preserves the old branch. | Observer values, invalid-scope reads, and retained branch identity |
| SB13 | Unreachable roots do not stay retained. | Weak-reference collection, timer state, observer values, and statistics |
| SB16 | Dynamic invalidation finishes observers with `Invalid_scope`. | Callback traces, finish reasons, observer reads, and timer state |
| MB06 | Continuous key presence preserves one child incarnation. Re-entry creates a fresh incarnation. | Builder calls, child state, observer values, and invalid-scope reads |
| MB08 | Input changes patch one persistent output. A no-change result preserves the output root. | Output bindings, root physical identity, and downstream diff |
| MB09 | Failed keyed work preserves child identity, scope validity, committed data, and the output root. | Child state, reads, callbacks, output roots, and retry |
| MB10 | Keyed work stays proportional to affected children and changes. | Comparison counters, selected-child visits, and diff events |
| MB11 | Diagnostics do not retain keys or values. | Statistics, DOT text, observer traces, and ownership probes |

This prototype directly observes private handles, slot counts, operation
counts, output values, and one weak reference.

It also observes the static allocation and wall time at the raw-kernel
boundary.

The prototype does not expose a public Signal operation.
Therefore, it does not prove complete compliance with any inherited row.

The static observation sets one integer source and stabilizes one static graph.
The final value read occurs after the measured batch.

The lifecycle observation uses a private eight-node arena.
It does not execute callbacks, dynamic edges, scopes, or keyed roots.

## Design It Twice

The comparison uses three complete private representations.
Each representation preserves dense integer addressing in the active value
journal.

### A. Monotonic slots with tombstones

Candidate A assigns a new slot to every new node incarnation.
It never reuses a slot.

This representation makes every historical slot stable.
It needs no generation check and no active-pass quarantine.

Its retained table grows with total churn.
For `live=10` and `churn=100000`, it retains `100010` slots.

Candidate A fails the bounded-retention requirement.

### B. Free-list generations with per-pass quarantine

Candidate B keeps a slot table, a free list, and a generation in each slot.
Reuse increments the generation before installing a new node.

A long-lived handle contains the slot and generation.
A stale handle cannot resolve a replacement node.

Retirement removes the node pointer from the slot table.
The retired slot enters the active-pass quarantine.

The allocator does not read the active-pass quarantine.
Therefore, it cannot reuse a current-pass retirement.

Commit keeps publication O(1).
Affected-only cleanup moves committed retirements from quarantine to the free
list.

Candidate B keeps the static journal as immediate integers.
It also bounds logical slot retention by concurrent lifecycle demand.

Its three enforced phases prevent new work from bypassing pending cleanup.
Its pass identity and slot generations fail before integer wrap.

### C. Epoch arena with compaction

Candidate C allocates inside an epoch arena.
Periodic compaction copies live entries and repairs their indices.

Compaction bounds retained slots.
It also visits the complete live table.

For `affected=1` and `live=100000`, compaction visits `100000` entries.
Candidate C fails the affected-only work requirement.

### Comparison

| Property | A monotonic tombstones | B generations and quarantine | C epoch compaction |
|---|---|---|---|
| Stale long-lived identity | Stable slot | `(slot, generation)` check | Repaired handle or indirection |
| Active journal entry | Slot integer | Slot integer | Epoch-relative index |
| O(1) commit | Yes | Yes | Yes between compactions |
| Same-pass reuse fence | Reuse never occurs | Per-pass quarantine | Epoch boundary |
| Retained table | Grows with churn | Bounded by concurrent demand | Bounded after compaction |
| Cleanup work | O(affected) | O(affected) | O(live) during compaction |
| Static allocation result | Not selected | 4 words | Not selected |
| Verdict | Rejected | Selected | Rejected |

Candidate B is the only lifecycle candidate that passes the discriminating
correctness, retention, and affected-work checks.
It hides reuse, generation checks, quarantine, pointer clearing, and rollback
ordering behind one private module.

## Selected private module

The production names can differ.
The private semantic interface has this shape:

```ocaml
module Node_lifecycle : sig
  type t
  type node
  type slot = private int
  type generation = private int
  type handle = private {
    slot : slot
    generation : generation
  }
  type pass
  type cleanup
  type phase = Idle | Active | Cleanup_pending

  type error =
    [ `Stale_handle
    | `Generation_overflow
    | `Pass_identity_exhausted
    | `Invalid_phase
    | `Missing_active_slot of slot ]

  val create : unit -> t
  val resolve : t -> handle -> (node, error) result
  val add_quiescent : t -> node -> (handle, error) result

  val begin_pass : t -> (pass, error) result
  val create_tentative : pass -> node -> (handle, error) result
  val retire : pass -> handle -> (unit, error) result
  val journal_first_write : pass -> handle -> (unit, error) result

  val commit : pass -> cleanup option
  val cleanup : cleanup -> unit

  val rollback :
    pass ->
    restore_topology:(unit -> unit) ->
    (unit, error) result
end
```

`node` is private and existential.
Issue 16 owns its generic typed-value representation.

For an absent, empty, or different-generation slot, the module returns
`Stale_handle`.

The module returns `Invalid_phase` for nested passes or lifecycle operations in
the wrong phase.

`begin_pass`, quiescent allocation, and rollback reject `Cleanup_pending`.
Cleanup rejects `Idle` and `Active`.

Rejected phase operations preserve actions, quarantine entries, node pointers,
and the current phase.

For an unresolved active journal slot, the module returns
`Missing_active_slot` during rollback.
This result identifies an internal invariant violation.

The kernel maps `Generation_overflow` to the documented
`` `Counter_overflow`` graph error.

The allocator checks `generation = max_int` before it changes any state.
Overflow leaves the generation, free list, action journal, and empty slot
unchanged.

`begin_pass` checks `pass_identity = max_int` before it changes any state.
It returns `Pass_identity_exhausted` and leaves all active lengths unchanged.

A pass at `max_int - 1` can commit or roll back to `max_int`.
No later pass can start.

The kernel maps both private overflow errors to the documented
`` `Counter_overflow`` graph error.

The `pass` value owns the active value journal, topology actions, and
quarantine.
Only one `pass` exists for a table.

The optional `cleanup` value represents committed lifecycle work.
The execution orchestrator consumes it before any callback starts.

A zero-action commit returns `None` and changes `Active` to `Idle`.
An affected commit returns `Some cleanup` and changes `Active` to
`Cleanup_pending`.

The `restore_topology` function restores affected scopes, edges, keyed tables,
and output roots.
Issue 08 supplies this private function.

The restore function has no public effects and does not raise.
Its failure is an internal invariant violation.

## Invariants

Each occupied slot has exactly one current generation and one node pointer.
Each free or quarantined slot has no node pointer.

Every long-lived reference uses a handle.
Only active-pass journals and proven pass-local topology entries use bare
slots.

The allocator increments a reused slot generation before it installs the new
node pointer.
An appended slot starts at generation zero.

A slot retired during a pass stays quarantined until cleanup or rollback
finishes.
The allocator never reuses that slot during the same pass.

The active value journal stores each first-written slot once.
Its entries are immediate integers and retain no nodes.

Commit sets the value-journal length to zero in O(1).
Commit does not scan slots, actions, or the graph.

Cleanup and rollback clear every affected pointer-bearing action entry.
Inactive array prefixes contain only non-pointer sentinels after either path.

Quiescence requires no active pass, no cleanup token, and zero active lengths.
It also requires empty topology work and scheduling work.

The phase is `Idle` before pass start.
Only `begin_pass` changes `Idle` to `Active`.

Only commit with actions changes `Active` to `Cleanup_pending`.
Only cleanup changes `Cleanup_pending` to `Idle`.

Rollback changes `Active` directly to `Idle`.
No operation starts from an unrecognized phase.

## Lifecycle transitions

The slot states are `Free`, `Live`, `Tentative`, and `Retired`.
`Committed_retired` is the short state between commit and cleanup.

### Tentative creation

A tentative creation starts during an active pass.
It takes a pre-pass free slot or appends one slot.

Reuse increments the generation first.
The slot then changes from `Free` to `Tentative`.

The module installs the node pointer and records `Created slot`.
The tentative node can enter the active value journal.

### Retirement

Retirement resolves the complete long-lived handle.
The module marks the node inactive and removes its pointer from the slot table.

The slot changes from `Live` to `Retired`.
The module adds it to the quarantine.

The topology action stores `Retired (slot, node)`.
This pointer exists only until cleanup or rollback.

### Commit

Commit publishes all in-place value writes and accepted topology.
It sets the active value-journal length to zero.

A `Tentative` slot becomes `Live`.
A `Retired` slot becomes `Committed_retired`.

Commit increments the pass identity and ends the active pass.
Its source contains no node loop.

With zero actions, commit changes the phase to `Idle`.
With actions, commit changes the phase to `Cleanup_pending`.

The probe records three semantic commit steps for action lengths 0, 1, 4, and
1,000.
This diagnostic counter adds instrumentation overhead to the prototype.

### Post-commit cleanup

Cleanup runs immediately after commit and before observer callbacks, timer
cleanup, disposal hooks, or other post-publication work.

Cleanup accepts only `Cleanup_pending`.
Pass start, quiescent allocation, and rollback cannot cross this fence.

Cleanup visits each topology action once.
It moves each `Committed_retired` slot to `Free`.

Cleanup keeps each created node in its `Live` slot.
It replaces every action entry with a non-pointer sentinel.

Cleanup then resets the action and quarantine lengths.
It changes the phase to `Idle`.
No full graph scan occurs.

Post-publication failures cannot use rollback.
They observe the committed snapshot after lifecycle cleanup.

### Rollback

Rollback has three node-lifecycle phases.
It visits actions and journal entries in reverse order.

Rollback accepts only `Active`.
It rejects `Idle` and `Cleanup_pending`.

Phase one restores retired slots without removing tentative nodes.
Each `Retired` slot receives its original node pointer and becomes `Live`.

After phase one, `restore_topology` restores affected scopes, edges, keyed
tables, and output roots.
This restoration occurs before tentative nodes disappear.

Phase two restores each first-written value.
Every active journal slot must resolve during this phase.

Phase three removes each tentative node.
Each `Tentative` slot loses its node pointer and enters the free list.

Phase three also clears all pointer-bearing topology action entries.
Rollback then resets all active lengths and increments the pass identity.

The rollback visit count is `2 * action length + value-journal length`.
This count excludes the affected topology work that issue 08 adds.

## Why active journals do not need generations

An active journal entry enters the buffer only after handle resolution.
It therefore identifies the current slot incarnation at that time.

A live slot cannot change incarnation during the same pass.
Retirement moves it to quarantine instead of the free list.

A tentative slot also cannot change incarnation during the same pass.
Only rollback returns it to the free list, and rollback ends the pass.

Commit sets the active length to zero.
The stale prefix becomes unreachable through the active journal boundary.

The next pass writes from journal index zero.
Each activated prefix entry therefore replaces its stale integer before use.

Long-lived handles do not use this argument.
They always retain and compare `(slot, generation)`.

## Removed-node retention

The stale value-journal prefix contains integers only.
It cannot retain a removed node.

A retirement action temporarily contains the removed node pointer.
Affected cleanup clears that entry after commit.

Rollback clears the same pointer after it restores the node or discards the
action.
Issue 08 must apply the same rule to pointer-bearing topology actions.

Retirement removes the node pointer from the slot table.
Successful cleanup leaves that slot empty and reusable.

The weak-reference probe retires one node, commits, and cleans the affected
entry.
Then a full major collection and compaction clear the weak reference.
This weak-reference check passes.

The arena remains live during this check.
Thus the weak result distinguishes node release from arena release.

## Independent checks and counterexamples

The probe checks stale handles before and after slot reuse.
It also checks stale tentative handles after failed-pass reuse.

The stale-prefix check reuses the old slot for a replacement node.
It poisons the replacement undo value with `-777`.

An empty rollback then leaves the replacement value at 20.
An incorrect stale-prefix rollback restores the poisoned value `-777`.

The next active write replaces journal entry zero with the reused slot.
Rollback then restores the replacement value from 21 to 20.

The probe checks successful and failed retirement.
It checks successful and failed tentative creation.

The mixed failure check writes and retires one node, then creates another node.
Rollback restores the first node and invalidates the second handle.

The touched-tentative check records exactly three rollback visits.
It then proves safe reuse with the next generation.

The missing-slot check removes an active journal node.
Rollback returns the exact `active value journal resolved to an empty slot`
failure.

The overflow checks exercise quiescent and tentative allocation.
Both preserve all allocator state after `Generation_overflow`.

The pass-boundary checks exercise commit and rollback from `max_int - 1`.
Both reach `max_int`, and each later `begin_pass` raises
`Pass_identity_exhausted`.

The rejected starts preserve phase, journal length, action length, and
quarantine length.

The cleanup-phase check rejects cleanup from `Idle` and `Active`.
It preserves one active tentative action after the rejected active cleanup.

After commit, the check observes `Cleanup_pending` with the retirement pointer
still retained.
It rejects pass start, quiescent allocation, and rollback in that phase.

Cleanup clears the action and quarantine.
It releases the retired pointer, returns `Idle`, and permits safe slot reuse.

The static checks require zero lifecycle entries and zero cleanup calls.
They record exactly three semantic commit steps.
The cutoff check also preserves the inherited static result.

The commit-step check uses action lengths 0, 1, 4, and 1,000.
Every commit records three semantic steps.

For each positive action length, cleanup visits equal the action length.
The commit source contains no node loop.

The churn checks use live counts 1, 10, and 100.
They run successful and failed churn for 1,024 and 100,000 operations.

Candidate A retains `100010` slots for `live=10` and `churn=100000`.
The expected live bound is 10.

Candidate C visits `100000` slots for `affected=1` and `live=100000`.
This visit count violates affected-only cleanup.

Candidate B retains at most `L + 1` logical slots in the tested
single-replacement pass.

In general, logical slot count is at most peak quiescent live nodes plus peak
simultaneous tentative creations.

Pre-pass free slots can satisfy tentative creation.
This reuse can decrease the exact count.
Current-pass retired slots do not reduce this bound because they stay
quarantined.

With doubling growth, physical slot-array capacity stays less than twice the
largest positive logical slot count.

The free, quarantine, action, and value-journal arrays have similar geometric
bounds against their largest active lengths.

## Measurement protocol

The authoritative results are in
[`summary.csv`](node-lifecycle-probe/summary.csv).
The complete samples are in
[`results.csv`](node-lifecycle-probe/results.csv).

The release build used the OxCaml Nix shell.
Each workload ran in a fresh process pinned to CPU 2.

Each pair shared one machine, toolchain, release profile, and probe
configuration.
An Eio backend does not apply to this raw probe.

The reference processes used installed Incremental version
`v0.18~preview.130.91+190`.
That package contains pinned source revision
`31eb755facdfcaaf4ccbae55dffd829f7c7278f9`.

The source provenance and raw K0 boundary are in
[Incremental layered baseline](incremental-layered-baseline.md).

Calibration started with one operation and doubled the operation count.
It stopped at 0.5 seconds or 16,777,216 operations.

Each process reported nine samples.
The run used three complete comparison pairs.

The summary contains the median for each process.
Each candidate row immediately followed its matching Incremental row.

The allocation formula was:

```text
minor words + major words - promoted words
```

Setup, graph construction, warm-up, the final check, and teardown stayed outside
the measured operation.
A full major collection ran before the measured samples.

One static operation set one source and stabilized once.
For an action length of zero, static passes bypassed lifecycle cleanup.

The checks required zero static cleanup calls and zero static lifecycle entries.

The probe reproduces the frozen raw workload boundary, graph formulas,
calibration, sampling, allocation formula, and process isolation.

The probe uses its separate throwaway executable.
It does not execute
[`bench/signal_compare/compare.ml`](../../../bench/signal_compare/compare.ml).

Candidate B is not integrated into production Signal or the frozen harness.
Therefore, these rows are prototype evidence, not a complete frozen-harness
gate.

Each lifecycle operation used a fixed graph of eight live nodes.
These rows measured one private lifecycle cycle.

The creation row replaced one node through tentative creation.
The retirement row cleaned one retirement before quiescent reuse.

The reuse row started with one committed free slot and cycled that slot.
The rollback row retired one node and rolled back the failed pass.

## Prototype static measurements

The reference is the matching raw Incremental process in the same pair.
The matrix comparison threshold is 1.20.

| Workload | Pair | Graph size | Candidate operations | Incremental operations | Incremental ns | Candidate ns | Observed ratio | Candidate words |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Changed depth 1 | 1 | 2 | 16,777,216 | 16,777,216 | 31.899205 | 15.080630 | 0.472759 | 4.000001 |
| Changed depth 1 | 2 | 2 | 16,777,216 | 16,777,216 | 33.187391 | 15.048030 | 0.453426 | 4.000001 |
| Changed depth 1 | 3 | 2 | 16,777,216 | 16,777,216 | 31.840926 | 15.042076 | 0.472413 | 4.000001 |
| Changed depth 10 | 1 | 11 | 16,777,216 | 8,388,608 | 102.117752 | 46.857068 | 0.458853 | 4.000001 |
| Changed depth 10 | 2 | 11 | 16,777,216 | 8,388,608 | 104.809772 | 46.672469 | 0.445306 | 4.000001 |
| Changed depth 10 | 3 | 11 | 16,777,216 | 8,388,608 | 100.926883 | 50.811877 | 0.503452 | 4.000001 |
| Changed depth 100 | 1 | 101 | 2,097,152 | 524,288 | 1034.417892 | 373.683406 | 0.361250 | 4.000005 |
| Changed depth 100 | 2 | 101 | 2,097,152 | 524,288 | 1032.167347 | 373.812099 | 0.362162 | 4.000005 |
| Changed depth 100 | 3 | 101 | 2,097,152 | 524,288 | 1029.430223 | 371.195256 | 0.360583 | 4.000005 |
| Cutoff depth 10 | 1 | 12 | 16,777,216 | 16,777,216 | 30.780555 | 12.108671 | 0.393387 | 4.000001 |
| Cutoff depth 10 | 2 | 12 | 16,777,216 | 16,777,216 | 30.684646 | 11.496311 | 0.374660 | 4.000001 |
| Cutoff depth 10 | 3 | 12 | 16,777,216 | 16,777,216 | 30.661454 | 11.489036 | 0.374706 | 4.000001 |

Allocation is 4.000001 / 4.000001 / 4.000005 / 4.000001
words.

Matching Incremental allocation is
0.000001 / 0.000001 / 0.000019 / 0.000001 words.

Every observed ratio is less than 1.20 in every pair.
These matching installed Incremental rows support the selected model.

Under a strict matrix interpretation, only the frozen harness can complete the
wall-time gate.
Issue 11 owns that integrated-finalist run.

The changed graphs contain one source and 1, 10, or 100 map nodes.
Their graph sizes are 2, 11, and 101.

The cutoff graph contains one source, one constant map, and ten dependent maps.
Its graph size is 12.

Calibration selected different operation counts for the depth-10 and depth-100
pairs.
Ratios use normalized nanoseconds for one operation.

## Lifecycle benchmark context

The lifecycle rows describe private candidate B costs.
They are not acceptance gates and have no matched Incremental operation.

| Workload | Pair 1 ns / words | Pair 2 ns / words | Pair 3 ns / words | Operations |
|---|---|---|---|---:|
| Tentative replacement | 23.794655 / 15.000001 | 23.824029 / 15.000001 | 23.828022 / 15.000001 | 16,777,216 |
| Retirement and cleanup | 18.243909 / 13.000001 | 18.211892 / 13.000001 | 18.177573 / 13.000001 | 16,777,216 |
| Free-slot reuse | 16.486410 / 13.000001 | 16.470906 / 13.000001 | 16.489693 / 13.000001 | 16,777,216 |
| Failed retirement rollback | 14.975186 / 5.000001 | 14.912786 / 5.000001 | 15.356903 / 5.000001 | 16,777,216 |

Each lifecycle row uses graph size 8.
Each operation returns the arena to eight live nodes and a quiescent state.

The performance matrix defines an issue 08 edge row against pinned Eta.
These private timings do not replace those future rows.

## Rejections

Reject candidate A because retained logical slots grow with historical churn.
Generation-free identity does not offset unbounded retention.

Reject candidate C because compaction scans all live slots.
Its full-table repair violates the affected-work gate.

Do not add generations to active value-journal entries.
That change adds data without strengthening the pass-local identity invariant.

Do not reuse current-pass retired slots.
Same-pass reuse lets an active integer journal entry identify another
incarnation.

Do not retain removed node pointers in inactive journal prefixes.
Only affected cleanup or rollback clears pointer-bearing actions safely.

## Limits

The probe uses integer values and unary static propagation.
It does not prove generic or boxed value storage.

The lifecycle model omits dynamic edges, scopes, keyed tables, and output roots.
It does not prove their rollback order or identity behavior.

The probe does not prove callback ordering, observer failure, timer cleanup,
Effect behavior, Eio behavior, cancellation, or multi-domain behavior.

The weak-reference result depends on the OCaml garbage collector.
It demonstrates the tested retention path, not every future topology entry.

The geometric capacity statement covers the selected doubling policy.
A production growth policy needs the same logical bound.

The static comparison measures a prototype-specialized integer kernel.
It is not a complete public Signal comparison.

The probe checks private pass exhaustion.
It does not execute the public `` `Counter_overflow`` mapping.

The separate executable does not satisfy a strict requirement to execute
`bench/signal_compare/compare.ml`.
Issue 11 must run the integrated finalist in that frozen harness.

## Decision

Use candidate B.
Keep generation-safe long-lived handles and pass-local integer journals.

The selection has high confidence for identity safety, bounded retention,
allocation, and affected-only lifecycle work.

The wall-time evidence remains provisional until issue 11 runs the integrated
finalist in the frozen harness.
This qualification does not reopen the lifecycle model.

Candidates A and C fail discriminating retention or affected-work checks.
Candidate B also preserves the four-word prototype allocation result.

Quarantine current-pass retirements.
Reuse only slots that were free before the pass or became free after a completed
pass.

Keep commit O(1) by zeroing the active value-journal length.
Run affected-only lifecycle cleanup after commit and before callbacks.

Enforce `Idle`, `Active`, and `Cleanup_pending`.
Do not admit work across the cleanup-pending fence.

Check pass identities before pass start.
Map pass identity and slot generation exhaustion to `` `Counter_overflow``.

Use the three-phase rollback order.
Restore retirements, restore journaled values, and then discard tentative
creations.

Clear every affected pointer-bearing action during cleanup or rollback.
Never scan the complete graph for node lifecycle work.

## Constraints for issue 08

Issue 08 inherits these explicit constraints:

1. Topology journals use generation-safe long-lived handles or proven
   pass-local slots.
2. Current-pass retired slots stay quarantined until cleanup or rollback
   finishes.
3. A commit with lifecycle actions enters `Cleanup_pending`.
4. Pass start, quiescent allocation, and rollback reject `Cleanup_pending`.
5. Only affected cleanup consumes pending actions and returns the arena to
   `Idle`.
6. Cleanup visits only affected lifecycle and topology entries.
7. A failed structural pass restores scopes, edges, keyed roots, and output
   roots before it discards tentative nodes.
8. Structural rollback and cleanup perform no full graph scan.
9. Pointer-bearing topology actions clear during affected cleanup or rollback.
10. Pass identities use checked increments and fail before wrap.
11. Pass identity and generation exhaustion map to `` `Counter_overflow``.
12. Static passes keep zero lifecycle entries and preserve the four-word
   allocation result.
13. The dynamic-scope edge benchmark row remains owned by issue 08.

Issue 08 must prove dynamic edge, scope, and keyed behavior independently.
This prototype supplies lifecycle constraints, not that proof.
