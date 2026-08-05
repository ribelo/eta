# Edge-effect feasibility for Eta Signal

## Question and limits

This note examines the scalar changed-value benchmark at depth 1.

The supplied medians are:

- Eta: 10,626.569 ns and approximately 8,232 allocated words per operation.
- Jane Street Incremental: 33.805 ns per operation.
- The 1.20x target is 40.566 ns per Eta operation.

Eta is currently 314.3x slower than Incremental. Eta must remove 99.62% of its
measured time to meet the target.

The allowed local sources do not contain `.reference/incremental`. Therefore,
this note does not make claims about Incremental internals. It uses the
Incremental calls in the benchmark as the comparison boundary.

Source inspection identifies allocation sites, but it cannot give exact
compiler allocation counts. The measured 8,232 words remain the allocation
total for this analysis.

The benchmark times `run_batch` and divides elapsed time and allocation counters
by the calibrated operation count
([compare.ml:426-458](../evidence/eta_incremental_performance/signal/compare.ml#L426-L458)).

## Judgment

**The current benchmark measures much more than the synchronous graph core.**
It measures Eta effect interpretation, lane ownership, transactions, callback
delivery, cleanup, and the graph computation.

The Eta and Incremental observation edges are also different. Eta installs an
effectful callback. Incremental installs only an observer handle in this
benchmark
([compare.ml:33-35](../evidence/eta_incremental_performance/signal/compare.ml#L33-L35),
[compare.ml:89-91](../evidence/eta_incremental_performance/signal/compare.ml#L89-L91)).
Eta must deliver that callback after each changed stabilization
([eta_signal.mli:336-360](../../../lib/signal/eta_signal.mli#L336-L360)).

**A small wrapper correction can make the benchmark fairer. It cannot close the
314.3x gap.** The synchronous core itself creates a transaction, staging data,
observer plans, commit plans, and delivery events for each operation.

**The 1.20x target is not feasible for the current public
`Var.set` plus `stabilize` path without an API and runtime redesign.** A
synchronous specialized path can make the target technically testable. The
present sources do not establish that this path can reach 40.566 ns.

## What the benchmark measures

### Root runtime cost is batched

Eta creates one recursive effect for a batch. Then it calls `Eta.Runtime.run`
once for the complete batch
([compare.ml:43-48](../evidence/eta_incremental_performance/signal/compare.ml#L43-L48)).
Thus, the result does not include one root `Runtime.run` call per scalar
operation.

The root call still creates a finalizer list and a runtime frame. It also enters
the task context and the finalizer boundary
([runtime.ml:14-41](../../../lib/eta/runtime.ml#L14-L41)).
These costs apply once per calibrated batch.

### The Eta loop adds per-operation effect work

The Eta loop allocates and interprets one recursive `Effect.bind` per operation
([compare.ml:43-47](../evidence/eta_incremental_performance/signal/compare.ml#L43-L47)).
The Incremental side uses a direct `for` loop
([compare.ml:94-100](../evidence/eta_incremental_performance/signal/compare.ml#L94-L100)).

The Eta step also interprets `Effect.sync`, two step binds, `Var.set`, and
`stabilize`
([compare.ml:37-41](../evidence/eta_incremental_performance/signal/compare.ml#L37-L41)).
`Effect.sync` creates a `Custom` effect. `Effect.bind` creates a `Bind` node
([effect_core.ml:66-86](../../../lib/eta/effect_core.ml#L66-L86),
[effect_core.ml:175-182](../../../lib/eta/effect_core.ml#L175-L182),
[effect_core.ml:302-310](../../../lib/eta/effect_core.ml#L302-L310)).

The benchmark creates the outer step once. However, its continuation creates a
new `Var.set` effect for each value. The recursive batch loop also creates its
next `Bind` node for each operation.

### The Eta observer adds callback protocol work

The Eta observer callback returns `Effect.unit`, but Eta still creates and
delivers a changed-value event. Delivery runs these stages:

1. Check that the observer is active.
2. Claim the delivery.
3. Construct the callback effect.
4. Check the delivery token.
5. Run the callback.
6. Acknowledge the delivery.

The runner sequence is explicit in
[eta_signal_observer.ml:356-387](../../../lib/signal/eta_signal_observer.ml#L356-L387).
The event implements each state operation through a separate effectful lane
access
([eta_signal_observer.ml:673-715](../../../lib/signal/eta_signal_observer.ml#L673-L715)).

Incremental has no callback in this workload. Therefore, the depth-1 comparison
does not isolate equivalent graph-core work.

## Exact Eta scalar call path

### `Var.set`

The changed-value path is:

```text
run_eta_batch
  -> Effect.bind step
  -> eta_step
  -> Effect.sync next_value
  -> S.Var.set
  -> with_graph_lane_access
  -> Graph.with_lane_access
  -> Eta_signal_lane.with_sync
  -> set_var_source_unlocked
  -> publish_source_current
  -> queue_var_unlocked
  -> Work.admit Sources
  -> Graph.enqueue_pending
```

`Var.set` enters the graph lane and converts its OCaml result to a typed effect
([eta_signal_kernel.ml:2886-2895](../../../lib/signal/kernel/eta_signal_kernel.ml#L2886-L2895)).
The synchronous mutation publishes the source value and queues the variable
([eta_signal_kernel.ml:1880-1888](../../../lib/signal/kernel/eta_signal_kernel.ml#L1880-L1888)).

The queue operation is constant-time. It prepends the variable to the pending
list
([eta_signal_graph.ml:70-75](../../../lib/signal/eta_signal_graph.ml#L70-L75)).
The removed graph-wide keyed scan is not present on this path.

### `stabilize`

The changed-value path then runs:

```text
S.stabilize
  -> allocate cleanup refs and finish state
  -> get the active runtime contract
  -> with_graph_lane_access
  -> create timer refresh context
  -> begin_stabilize
  -> Graph.run_stabilization
  -> Eta_signal_atomic_pass.run
  -> begin transaction and staging
  -> drain and stage the pending Var
  -> mark the watched signal dirty
  -> compute observed nodes
  -> collect an observer event
  -> prepare and apply the commit plan
  -> release the planning lane
  -> deliver the observer callback
  -> mark delivery complete
  -> run cleanup and finish delivery
```

`stabilize` first creates two refs and a mutable finish record
([eta_signal_kernel.ml:2833-2841](../../../lib/signal/kernel/eta_signal_kernel.ml#L2833-L2841),
[eta_signal_graph.ml:1587-1595](../../../lib/signal/eta_signal_graph.ml#L1587-L1595)).
It then gets the runtime contract and enters the graph lane
([eta_signal_kernel.ml:2842-2854](../../../lib/signal/kernel/eta_signal_kernel.ml#L2842-L2854)).

Eta creates a timer refresh context for every stabilization, including this
non-timer graph
([eta_signal_kernel.ml:2846-2853](../../../lib/signal/kernel/eta_signal_kernel.ml#L2846-L2853)).
That context is a five-field mutable record
([eta_signal_timer_policy.ml:18-24](../../../lib/signal/eta_signal_timer_policy.ml#L18-L24),
[eta_signal_timer_policy.ml:377-384](../../../lib/signal/eta_signal_timer_policy.ml#L377-L384)).

`begin_stabilize` builds pending, observer, commit, rollback, and stabilization
operation records
([eta_signal_kernel.ml:2750-2814](../../../lib/signal/kernel/eta_signal_kernel.ml#L2750-L2814)).
`Graph.run_stabilization` builds another atomic operation record before it calls
the synchronous atomic pass
([eta_signal_graph.ml:1533-1581](../../../lib/signal/eta_signal_graph.ml#L1533-L1581)).

The atomic pass creates a new planning transaction. Then it allocates refs for
staging, pending data, and observers
([eta_signal_atomic_pass.ml:237-250](../../../lib/signal/engine/transaction/eta_signal_atomic_pass.ml#L237-L250)).
The transaction allocates an identity ref and an eight-cell array
([eta_signal_transaction.ml:64-73](../../../lib/signal/engine/transaction/eta_signal_transaction.ml#L64-L73)).

The pass drains the pending variable and stages it
([eta_signal_atomic_pass.ml:256-270](../../../lib/signal/engine/transaction/eta_signal_atomic_pass.ml#L256-L270)).
Staging compares the source and graph values. A change stages the graph value,
collects watchers, and marks them dirty
([eta_signal_kernel.ml:1991-1997](../../../lib/signal/kernel/eta_signal_kernel.ml#L1991-L1997)).

The scheduler computes the observed graph in a synchronous loop
([eta_signal_kernel.ml:2385-2403](../../../lib/signal/kernel/eta_signal_kernel.ml#L2385-L2403)).
The depth-1 computation evaluates the variable and map nodes through recursive
`compute` calls
([eta_signal_kernel.ml:2022-2089](../../../lib/signal/kernel/eta_signal_kernel.ml#L2022-L2089)).

Observer collection filters and sorts the observer list before it collects
events
([eta_signal_observer.ml:839-856](../../../lib/signal/eta_signal_observer.ml#L839-L856)).
This work occurs even with one observer.

The commit preparation maps computed nodes and creates write closures for
signals and final staging cleanup
([eta_signal_graph.ml:199-236](../../../lib/signal/eta_signal_graph.ml#L199-L236)).
The atomic pass adds four more write closures for transaction and delivery state
([eta_signal_atomic_pass.ml:274-301](../../../lib/signal/engine/transaction/eta_signal_atomic_pass.ml#L274-L301)).
The plan reverses its write list and allocates hook lists during application
([eta_signal_commit_plan.ml:82-104](../../../lib/signal/engine/transaction/eta_signal_commit_plan.ml#L82-L104)).

After planning, Eta runs effectful cleanup and callback delivery
([eta_signal_kernel.ml:2857-2870](../../../lib/signal/kernel/eta_signal_kernel.ml#L2857-L2870)).
Delivery itself uses `Effect.bind` and nested `Effect.on_exit` boundaries
([eta_signal_atomic_pass.ml:337-348](../../../lib/signal/engine/transaction/eta_signal_atomic_pass.ml#L337-L348)).

## Lane and runtime fixed costs

`with_graph_lane_access` creates an effectful lane operation
([eta_signal_kernel.ml:891-900](../../../lib/signal/kernel/eta_signal_kernel.ml#L891-L900)).
Each non-reentrant lane entry does this work:

- Read a runtime-local depth value.
- Read the current fiber identity.
- Acquire the `Sync_lock`.
- Create an access token.
- Create an access ref.
- Install a runtime-local binding.
- Create a release effect.
- Create `Bind` and `on_exit` effects.
- Release the lock through a protected cleanup scope.

The implementation shows this sequence in
[eta_signal_lane.ml:267-311](../../../lib/signal/eta_signal_lane.ml#L267-L311).
The access token itself contains a new ref
([eta_signal_lane.ml:73-77](../../../lib/signal/eta_signal_lane.ml#L73-L77)).

Each lane release creates a temporary queue and a `Fun.protect` finalizer
([eta_signal_lane.ml:159-166](../../../lib/signal/eta_signal_lane.ml#L159-L166),
[eta_signal_lane.ml:254-265](../../../lib/signal/eta_signal_lane.ml#L254-L265)).
The lock also uses domain-local state and atomic owner state
([sync_lock.ml:49-70](../../../lib/eta/sync_lock.ml#L49-L70)).

One changed operation uses at least nine non-contended lane sections:

1. `Var.set`.
2. Stabilization planning.
3. Observer active check.
4. Observer claim.
5. Callback construction.
6. Callback token check.
7. Observer acknowledgment.
8. Delivery completion.
9. Stabilization finish.

The five observer sections come from the separate accesses in
[eta_signal_observer.ml:682-711](../../../lib/signal/eta_signal_observer.ml#L682-L711).
Completion and finish each enter the lane
([eta_signal_graph.ml:1627-1635](../../../lib/signal/eta_signal_graph.ml#L1627-L1635)).

`Effect.on_exit` runs each cleanup in a new effect scope
([effect_resource.ml:6-31](../../../lib/eta/effect_resource.ml#L6-L31)).
That scope allocates a finalizer ref and a child runtime frame
([effect_core.ml:138-162](../../../lib/eta/effect_core.ml#L138-L162)).

These operations explain why moving only `Runtime.run` cannot correct the
result. The benchmark already batches that root edge.

## Are effects only at public edges?

### Eta Signal

The answer is **partly**.

The graph mutation and planning core is synchronous. `Var.set` calls a
synchronous mutation under one lane effect. Stabilization calls the atomic pass
synchronously under another lane effect
([eta_signal_kernel.ml:2886-2895](../../../lib/signal/kernel/eta_signal_kernel.ml#L2886-L2895),
[eta_signal_graph.ml:1579-1581](../../../lib/signal/eta_signal_graph.ml#L1579-L1581)).

Effects are not limited to the outer public edge. Observer delivery, cleanup,
timer demand, and finish logic compose effects after planning. The scalar
workload executes this internal effect protocol even though its callback is
`Effect.unit`
([eta_signal_kernel.ml:2825-2870](../../../lib/signal/kernel/eta_signal_kernel.ml#L2825-L2870)).

### Eta Signal Map

`Eta_signal_map.Make` includes the Eta Signal kernel directly
([eta_signal_map_api.ml:70-73](../../../lib/signal_map/api/eta_signal_map_api.ml#L70-L73)).
The scalar benchmark instantiates this module, but it does not call `Keyed`.
It uses only `Var`, `map`, `Observer`, and `stabilize`
([compare.ml:3-3](../evidence/eta_incremental_performance/signal/compare.ml#L3-L3),
[compare.ml:50-68](../evidence/eta_incremental_performance/signal/compare.ml#L50-L68)).

Therefore, Eta Signal Map adds no keyed-map work to the scalar result. Its map
container implementation is synchronous and contains no Eta effects
([eta_signal_map_api.ml:74-106](../../../lib/signal_map/api/eta_signal_map_api.ml#L74-L106),
[eta_signal_map_kernel.ml:19-42](../../../lib/signal_map/kernel/eta_signal_map_kernel.ml#L19-L42)).

## Allocation inventory for one changed operation

The source establishes these allocation classes:

| Area | Per-operation allocation sources |
|---|---|
| Benchmark | Recursive loop `Bind` and its continuation |
| `Var.set` | Lane `Custom`, `flatten_result` `Bind`, access token, access ref, release effect, cleanup wrappers, temporary release queue |
| Stabilize edge | Two refs, finish record, runtime-contract bind, lane wrappers |
| Timer setup | Refresh-context record even without timers |
| Planning | Operation records and closures, planning transaction, identity ref, eight-cell array, staging token |
| Graph work | Pending list, computed-node list, staged cell entries, scheduler and snapshot values |
| Observer work | Selection records, filtered and sorted lists, event record, event closures, callback delivery effects |
| Commit | Commit-plan record, prepared signal list, write closures, reversed write list, hook-list cells |
| Cleanup | `on_exit` `Custom` values, cleanup scopes, finalizer refs, child frames |

The cited construction sites are:

- Effect representation:
  [effect_core.ml:66-93](../../../lib/eta/effect_core.ml#L66-L93).
- Lane construction and release:
  [eta_signal_lane.ml:159-166](../../../lib/signal/eta_signal_lane.ml#L159-L166),
  [eta_signal_lane.ml:267-303](../../../lib/signal/eta_signal_lane.ml#L267-L303).
- Transaction and staging:
  [eta_signal_transaction.ml:64-73](../../../lib/signal/engine/transaction/eta_signal_transaction.ml#L64-L73),
  [eta_signal_graph.ml:51-63](../../../lib/signal/eta_signal_graph.ml#L51-L63).
- Observer event:
  [eta_signal_observer.ml:673-715](../../../lib/signal/eta_signal_observer.ml#L673-L715).
- Commit plan:
  [eta_signal_graph.ml:199-236](../../../lib/signal/eta_signal_graph.ml#L199-L236),
  [eta_signal_atomic_pass.ml:282-301](../../../lib/signal/engine/transaction/eta_signal_atomic_pass.ml#L282-L301).

This inventory does not assign exact words to each site. Compiler optimization,
closure sharing, and backend runtime code determine those exact counts.

## Architectural seams

### Seam 1: Correct the benchmark wrapper

The first correction belongs only in the research benchmark.

Use equal loop forms for both systems. A scratch Eta loop can use one custom
effect leaf and evaluate the prebuilt step repeatedly. This change removes the
recursive public `Effect.bind` loop, but it preserves `Var.set` and
`stabilize`.

Also separate observer-value maintenance from callback delivery. The current
Eta public API has no observer constructor without a callback
([eta_signal.mli:333-340](../../../lib/signal/eta_signal.mli#L333-L340)).
Thus, an equal observer-only benchmark needs a scratch kernel seam or a new
public API.

This experiment is a wrapper correction. It does not change production
architecture.

### Seam 2: Fuse scalar set and planning under one lane

`set_var_source_unlocked` is already synchronous
([eta_signal_kernel.ml:1886-1888](../../../lib/signal/kernel/eta_signal_kernel.ml#L1886-L1888)).
`Eta_signal_atomic_pass.run` is also synchronous
([eta_signal_atomic_pass.ml:237-301](../../../lib/signal/engine/transaction/eta_signal_atomic_pass.ml#L237-L301)).

A private scalar step can set the source and run planning under one lane
acquisition. The public effect can remain outside that private operation.
This seam removes one lane edge and intermediate effect values.

This change is not sufficient for 40.566 ns. It preserves the complete
transaction, observer, commit, and delivery machinery.

### Seam 3: Split pure publication from effectful delivery

The current code already separates planning from delivery
([eta_signal_atomic_pass.ml:237-301](../../../lib/signal/engine/transaction/eta_signal_atomic_pass.ml#L237-L301),
[eta_signal_atomic_pass.ml:319-348](../../../lib/signal/engine/transaction/eta_signal_atomic_pass.ml#L319-L348)).
However, delivery performs five lane accesses for one changed observer.

The runtime can claim and construct one callback in one lane section. It can run
the callback outside the lane. Then it can acknowledge in one lane section.
This design preserves the rule that user callbacks do not run under the lane.

This seam is an internal runtime redesign. It changes cancellation and callback
state transitions, so it needs protocol tests.

### Seam 4: Add a persistent synchronous fast path

The 1.20x target needs a path that avoids per-step construction of:

- A timer context when the graph has no timers.
- A transaction identity and eight-cell array.
- Operation and plan records.
- Sorted observer lists for one observer.
- Commit write closures and hook lists.
- Callback protocol state when the observer requests values only.

This path needs persistent reusable work storage and specialized scalar
publication. Make it a separate explicit API with a restricted contract.
Reject unsupported graph features instead of selecting the current path
silently.

This is an API and runtime redesign, not a wrapper correction. A silent fast
path is unsafe unless it preserves the same transaction and cancellation
contract.

## Recommended next experiment

Add a scratch-only three-way benchmark. Do not change production code for the
first result.

1. Measure the current public workload with a direct scratch loop.
2. Measure an observer-value workload that does not create or deliver callbacks.
3. Measure a private fused scalar step under one lane acquisition.

Instrument these phase boundaries with allocation counters:

- Before and after `Var.set`.
- Before and after lane entry.
- Before and after synchronous planning.
- Before and after observer event collection.
- Before and after commit.
- Before and after effectful delivery.

Report time and allocated words for each phase. Use depth 0, 1, 10, and 100.
The depth slope will separate fixed edge cost from graph computation.

Use these decision thresholds:

- If the fused synchronous path is more than 40.566 ns at depth 1, wrappers
  cannot meet the target.
- If planning alone exceeds 40.566 ns, the transaction and graph runtime need a
  specialized fast path.
- If planning is within target but delivery is not, add a value-only observer
  API and redesign callback delivery separately.

## Final feasibility statement

Eta Signal already has a synchronous planning core, but effects do not stay at
public edges. The scalar public path repeatedly re-enters effect and lane
machinery during callback delivery.

The benchmark overstates graph-core cost because it includes Eta callback
semantics and an effectful loop. Correct those two benchmark edges first.

That correction cannot plausibly remove 99.62% of measured time. The source
shows substantial fixed synchronous transaction and commit work after all
effect wrappers are removed.

Reaching within 1.20x of 33.805 ns requires a specialized synchronous API and
runtime path. The target is **not feasible as a small wrapper optimization**.
It is **conditionally feasible only after the proposed experiment proves that
the reduced synchronous core fits within 40.566 ns**.
