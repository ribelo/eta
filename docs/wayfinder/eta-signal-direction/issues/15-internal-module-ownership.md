# Internal module ownership

Type: grilling
Status: resolved
Blocked by: 09, 10, 11, 12, 13

## Question

Which private modules and seams make the chosen Eta Signal design deep and
local?

Assign each transaction, phase, scheduling, demand, topology, observer, timer,
stream, keyed, diagnostic, and testing invariant to one module. Apply the
deletion test to wrappers and callback records. Keep a private seam only when it
owns an invariant or supports real variation.

Resolve F5, F6, and F14. Do not simplify by merging unrelated responsibilities
into one kernel file.

Decide the bounded tombstone-index representation. Ticket 05 found that each
insertion scans up to 1,024 retained tombstones during invalidation.

For each unused private abstraction, compare deliberate retention, canonical
adoption, replacement, and removal. Lack of current production use does not
select one option. If the abstraction suggests an externally useful interface,
coordinate engine and package seams with ticket 12. Coordinate public Signal
algebra with ticket 13.

## Answer

Use one private engine library. Group its modules by the data and authority that
each module owns. The directory layout can group related phases, but a directory
does not own an invariant.

`Eta_signal_kernel` remains the composition root. It constructs concrete node
kinds and connects the private modules. It does not contain their algorithms.

This design accepts the F5 concern. It rejects a universal two-use rule and a
universal ban on closure records. A private seam survives only when its type
owns an invariant or supports actual variation.

### Transaction and planning owners

| Private module | One named invariant |
|---|---|
| `Eta_signal_atomic_pass` | **Phase authority.** Rollback exists only during `Planning`. `Delivering` has no rollback path. |
| `Eta_signal_transaction` | **Atomic staging.** One physical token publishes or discards all owned staged cells. |
| `Eta_signal_commit_plan` | **Total commit.** Only a sealed and fully validated mutation tape can change committed state. |
| `Eta_signal_cleanup` | **Cleanup linearity.** Each provisional resource and hook reaches one terminal disposition. |
| `Eta_signal_node` | **Node lifetime.** Each node makes one valid-to-invalid transition. |
| `Eta_signal_scope` | **Scope lifetime.** A scope changes from valid to invalid at most once. |
| `Eta_signal_topology` | **Edge consistency.** Each committed edge has matching parent, child, and vector-slot records. |
| `Eta_signal_demand` | **Demand contribution.** An edge contributes one reference exactly when its final parent is necessary. |
| `Eta_signal_observer_plan` | **Delivery order.** The final prospective topology produces one deterministic total topological event order. |
| `Eta_signal_stable_family_plan` | **Edit ownership.** Each stable-family edit has one owner and one commit-or-discard decision. |

The types expose prepared changes, not projections of the kernel record.
`Eta_signal_commit_plan` receives typed proposals from topology, demand, bind,
and stable-family planning.

The plan closes the invalidation frontier before it seals the mutation tape.
The sealed plan exposes one total commit operation. It does not expose a partial
mutation operation or rollback authority.

### Execution and delivery owners

| Private module | One named invariant |
|---|---|
| `Eta_signal_work` | **Quiescence.** The graph is quiescent exactly when all work-class counts are zero. |
| `Eta_signal_scheduler` | **Frontier completion.** Each actionable node completes once after its necessary stale dependencies. |
| `Eta_signal_observer` | **Cursor uniqueness.** An active observer has at most one pending or running delivery token. |
| `Eta_signal_observer_delivery` | **Delivery termination.** One lane mutation makes each claimed token acknowledged, pending, or terminally finished. |
| `Eta_signal_timer_policy` | **Desired timer state.** Demand and monotonic time produce one desired lifecycle state. |
| `Eta_signal_timer` | **Generation fence.** Only the current running generation can publish a timer update. |

`Eta_signal_work` owns the O(1) admission decision from Ticket 10.
`Eta_signal_scheduler` owns the necessary-stale deque and dependency-first
evaluation. The work ledger does not implement scheduling.

`Eta_signal_observer_plan` freezes event order before commit.
`Eta_signal_observer_delivery` owns sequential fail-fast execution after commit.
`Eta_signal_observer` owns the durable cursor across attempts.

### Infrastructure owners

| Private module | One named invariant |
|---|---|
| `Eta_signal_lane` | **Exclusive access.** One valid lane capability owns effectful graph mutation at a time. |
| `Eta_signal_id` | **Role separation.** Signal, scope, variable, and observer identities cannot be interchanged. |
| `Eta_signal_error` | **Failure classification.** Expected failures stay typed, and callback exceptions stay defects. |
| `Eta_signal_diagnostics` | **Noninterference.** Diagnostic reads expose committed metadata without changing engine state. |
| `Eta_signal_tombstone_index` | **Bounded retention.** The index retains at most the latest 1,024 invalid-node snapshots. |
| `Eta_signal_test_probe` | **Typed inspection.** Each test probe preserves its graph brand and identity role. |
| `Eta_signal_kernel` | **Graph construction.** `Eta_signal.Make` remains the only graph factory. |

The private graph value is an aggregate of abstract owned states. It does not
restore the current graph-wide catalog of callback records.

Counter policy stays local. `Eta_signal_id` owns checked identity allocation.
`Eta_signal_diagnostics` owns saturating diagnostic counters and checked public
reads. `Eta_signal_timer_policy` owns deadline arithmetic and cadence caps.
`Eta_signal_lane` owns waiter and cancellation-debt saturation.

There is no generic safe-arithmetic module. These arithmetic policies have
different failure contracts and different commit effects.

### Bounded tombstone index

Use a fixed circular array with 1,024 slots:

```ocaml
type t = {
  slots : tombstone option array;
  mutable next : int;
  mutable count : int;
}
```

The graph allocates all slots during construction. The first valid-to-invalid
transition writes one slot and advances `next` modulo 1,024.

When the array is full, the write replaces the oldest snapshot. `count` stays
between zero and 1,024. Iteration visits snapshots from newest to oldest.

`Eta_signal_node` owns insertion uniqueness. It calls the index only for the
first valid-to-invalid transition. An invalid node cannot produce a second
insertion request.

The index does not scan for duplicates. This choice keeps the invalidation path
constant. The node validity check makes a second request an engine defect before
the index call.

Each snapshot contains identities, node kind, scope metadata, timer metadata,
dependency identities, and state flags. It contains no user value, key, output,
closure, log, or history.

Insertion takes O(1) work. Count takes O(1) work. A complete diagnostic
iteration visits at most 1,024 snapshots.

Explicit diagnostics can build a temporary identity table from the ring. This
bounded read does not add work to invalidation.

The ring preserves deterministic DOT order and bounded value-free diagnostics.
Invalid observer records remain separate. They can report a missing observed
signal after the matching tombstone leaves the ring.

Ticket 16 owns a deterministic gate for one slot write and at most one eviction
for each insertion. That gate replaces the old `sum min(i, 1024)` scan.

### Deletion test

A private abstraction remains when one of these conditions applies:

1. It owns one named invariant from the tables in this answer.
2. Its type makes an illegal phase transition unrepresentable.
3. It supports two actual adapters with one common semantic contract.
4. OCaml requires its record for rank-2 polymorphism.

Use count does not decide retention. A single-use phase type can pass this test.
A frequently used forwarding wrapper can fail it.

Delete a wrapper that only renames one call or projects one kernel record.
Delete a callback record when one concrete caller supplies its only adapter.
Do not recreate a deleted protocol under a new name.

Keep the sealed `Package_graph` and `For_stream` capabilities from Tickets 12
and 13. They support sibling packages and enforce graph branding.

### Current module dispositions

| Current module or seam | Final disposition |
|---|---|
| `Eta_signal_bind` | Replace its callback protocol with bind proposals for `Eta_signal_commit_plan`. |
| `Eta_signal_cleanup` | Rewrite it as the cleanup ledger. |
| `Eta_signal_debug` | Replace it with diagnostics and tombstone-index owners. |
| `Eta_signal_error` | Retain it as the shared failure vocabulary. |
| `Eta_signal_graph` | Delete it after its state moves to named invariant owners. |
| `Eta_signal_graph_algorithms` | Delete it after the algorithm dispositions below. |
| `Eta_signal_id` | Retain it and add checked role-specific allocation. |
| `Eta_signal_lane` | Retain it as the lane-authority owner. |
| `Eta_signal_observer` | Rewrite it as observer state. Move planning and delivery to separate owners. |
| `Eta_signal_scope` | Retain concrete scope state. Delete its callback functors. |
| `Eta_signal_stabilization` | Replace it with `Eta_signal_atomic_pass`. |
| `Eta_signal_stabilization_pass` | Delete it after its commit logic moves to `Eta_signal_commit_plan`. |
| `Eta_signal_timer` | Retain only concrete lifecycle execution. |
| `Eta_signal_timer_policy` | Retain pure desired-state and time policy. Move demand ownership out. |
| `Eta_signal_transaction` | Rewrite it around physical transaction identity. |
| Inline `Stream_bridge` | Move it to the private implementation of `eta_signal_stream`. |
| `Owner_transaction` | Delete it. Eta Crux owns its root transaction model. |
| `eta_signal_support` | Delete this Dune library. Use one private engine library. |

The current graph and stabilization interfaces combine unrelated invariants.
Their many port records exist for one kernel adapter. Splitting the owned state
removes the reason for those records.

### Graph-algorithm dispositions

All six graph functors leave the target design. Invariant ownership, not
production use count, selects this result.

| Current abstraction | Final disposition |
|---|---|
| `Make_edges` | Replace it with indexed edge operations in `Eta_signal_topology`. |
| `Make_reachable` | Remove it. Scheduler, demand, validation, and observer planning need different traversals. |
| `Make_order` | Remove it. Ticket 11 rejects its pairwise reachability comparator. |
| `Make_versions` | Remove it. Necessary-stale scheduling replaces dependency-version polling. |
| `Make_dirty` | Remove it. `Eta_signal_scheduler` becomes the canonical dirty-state owner. |
| `Make_compute` | Remove it. The explicit-stack scheduler replaces recursive generation-based computation. |
| `Demand` | Replace it with concrete reference transitions in `Eta_signal_demand`. |
| `Weak_cell` | Move weak live-node registry behavior to `Eta_signal_diagnostics`. |
| `Snapshot` | Move staged value behavior to `Eta_signal_transaction`. |
| `Value_cutoff` | Move cutoff interpretation behind `Eta_signal.Cutoff`. |
| `Static_eval` | Move its node evaluation into the scheduler path. It owns no separate invariant. |

The five test-only functors do not survive as test seams. Their algorithms are
obsolete or move to the canonical owner. Tests move to topology, scheduler,
demand, transaction, observer-plan, and cutoff suites.

`Make_edges` has one production instance. Its replacement must land before its
deletion. This order distinguishes replacement from deletion based on use count.

### Port-record dispositions

Delete these single-adapter protocol families:

- graph identity, edge, dirty, compute, version, order, and reachability ports
- graph staging and stabilization callback records
- observer activation, collection, lifecycle, and delivery ports
- timer state, access, demand-effect, and daemon-context ports
- scope validation and invalidation functors
- one-constructor wrappers that immediately call one stored closure

Concrete private modules receive abstract owned state and typed prepared
changes. Typed fault slots remain explicit test inputs. They do not become
general production mutation handles.

A retained private record must own one named invariant, seal phase authority,
satisfy rank-2 polymorphism, or support real adapter variation. This rule keeps
the correction local without a universal record ban.

### Stream package

`Eta_signal_stream_bridge` owns one invariant in the optional
`eta_signal_stream` package: each offered update gets one sent-or-dropped
outcome, then one acknowledgement.

Move the entire inline bridge from `Eta_signal_kernel` to
`lib/signal_stream/private/eta_signal_stream_bridge.ml`. The bridge uses only
the public sealed `Signal.For_stream` capability for Signal access.

The `eta_signal` package no longer depends on `eta_stream`, Eio, or Cstruct.
The `eta_signal_stream` package depends on `eta_signal`, `eta_stream`, and
`eta_observability`. The last dependency reports a defect from the drop hook.

Do not keep a fallback bridge in the core package. Do not add a public expert
surface for its queue protocol.

### Target file layout

Use one private engine library under `lib/signal/engine/`:

```text
lib/signal/engine/
  transaction/
    eta_signal_atomic_pass.ml/.mli
    eta_signal_transaction.ml/.mli
    eta_signal_commit_plan.ml/.mli
    eta_signal_cleanup.ml/.mli
    eta_signal_node.ml/.mli
    eta_signal_scope.ml/.mli
    eta_signal_topology.ml/.mli
    eta_signal_demand.ml/.mli
    eta_signal_observer_plan.ml/.mli
    eta_signal_stable_family_plan.ml/.mli
  execution/
    eta_signal_work.ml/.mli
    eta_signal_scheduler.ml/.mli
    eta_signal_observer.ml/.mli
    eta_signal_observer_delivery.ml/.mli
    eta_signal_timer_policy.ml/.mli
    eta_signal_timer.ml/.mli
  infrastructure/
    eta_signal_lane.ml/.mli
    eta_signal_id.ml/.mli
    eta_signal_error.ml/.mli
    eta_signal_diagnostics.ml/.mli
    eta_signal_tombstone_index.ml/.mli
    eta_signal_test_probe.ml/.mli
  eta_signal_kernel.ml
  dune
```

The subdirectories are organizational only. Their Dune stanzas build one
private engine library.

The optional stream package uses this layout:

```text
lib/signal_stream/
  eta_signal_stream.ml/.mli
  private/eta_signal_stream_bridge.ml/.mli
```

Delete `lib/signal/eta_signal_graph.ml`, its interface, and
`eta_signal_graph_algorithms` after their callers move. Delete both old
stabilization modules after atomic-pass and commit-plan adoption.

Delete the old kernel Dune stanza and the `eta_signal_support` stanza after the
private engine library contains all owners. No compatibility library remains.

### Implementation order

1. Replace transaction, cleanup, commit, and phase paths. Delete both old
   stabilization modules. Move their direct tests in this slice.
2. Replace bind and stable-family paths with plan proposals. Delete their old
   commit protocols. Move their direct tests in this slice.
3. Replace edge, demand, work, and scheduler paths. Delete their old algorithms
   and ports. Move their direct tests in this slice.
4. Replace observer planning, delivery, and timer reconciliation. Delete their
   old ports. Move their direct tests in this slice.
5. Replace diagnostics with the fixed tombstone ring. Delete the old debug and
   tombstone paths. Move their direct tests in this slice.
6. Extract `eta_signal_stream`. Delete the inline bridge and move its direct
   tests in this slice.
7. Delete the empty graph files and old Dune stanzas. Reduce the kernel to node
   construction and public-module wiring.

Each slice adopts one replacement and deletes its old behavior path. The
implementation does not add a compatibility shim or retain two behavior paths.

Correctness owners from Ticket 09 land before their old orchestration paths
leave. Scheduler and topology owners from Ticket 10 land before the old graph
algorithms leave.

The Signal Map adapter changes to `Eta_signal_map.Make(Signal.Package)`.
It does not depend on the private engine library.

Eta Crux deletes its `Owner_transaction` use in the same implementation route.
It compiles each root into the public Signal and Signal Map package seams from
Ticket 14.

### Test migration

Move graph-edge tests to topology tests. Move reachability, dirty, version, and
compute tests to scheduler and demand tests.

Merge stabilization and stabilization-pass tests into atomic-pass and
commit-plan tests. Keep transaction, cleanup, lane, timer, observer, and public
contract tests at their invariant owners.

Move stream bridge tests to `test/signal_stream/`. Replace unsafe extension
tokens with graph-branded role-specific probes.

Add direct tombstone-index tests for zero, one, 1,024, and 1,025 insertions.
Test newest-first iteration, exact eviction, value freedom, and invalid-observer
survival after eviction.

Ticket 16 owns the production economics gates and the complete law matrix. This
ticket identifies the test destinations but does not add durable tests.

### Cross-ticket census scope

Ticket 01 already resolves the F6 inventory rows `F06-001`, `F06-002`,
`F06-004`, and `F06-005`. This answer consumes that inventory without changing
its owner.

Ticket 17 owns the final review verdict `F14-001`. This answer settles all F14
module and route rows. Ticket 17 will use this answer for the final F14 verdict.

### Resolution spans

Line numbers refer to this issue.

| Census row | Resolution |
|---|---|
| F05-001 | lines 31–105 and 169–194 |
| F05-002 | lines 169–194 and 222–239 |
| F05-003 | lines 150–194 and 222–239 |
| F05-004 | lines 42–63 |
| F05-005 | lines 42–82 |
| F05-006 | lines 38–40 and 150–167 |
| F05-007 | lines 38–40 and 222–239 |
| F05-008 | lines 150–167 |
| F05-009 | lines 169–194 |
| F05-010 | lines 150–167 |
| F05-011 | lines 42–105 and 150–194 |
| F05-012 | lines 42–105 and 169–186 |
| F05-013 | lines 65–74 and 99–105 |
| F05-014 | lines 311–333 |
| F05-015 | lines 311–333 |
| F05-016 | lines 222–239 |
| F05-017 | lines 169–194 and 222–239 |
| F06-003 | lines 196–220 |
| F06-006 | lines 196–220 |
| F06-007 | lines 215–217, 311–333, and 342–359 |
| F06-008 | lines 196–220 |
| F06-009 | lines 215–217 and 342–359 |
| F06-010 | lines 219–220 and 311–333 |
| F06-011 | lines 196–220 and 311–333 |
| F14-002 | lines 241–256 |
| F14-003 | lines 241–256 |
| F14-004 | lines 99–105 |
| F14-005 | lines 99–105 |
| F14-006 | lines 99–105 |
| F14-007 | lines 99–105 |
| F14-008 | lines 241–256 |
| F14-009 | lines 84–105 |
| F14-010 | lines 84–105 |
| F14-011 | lines 311–333 |
| F14-012 | lines 241–256 and 311–340 |
| N05-010 | lines 42–63 |
| PLN-14-001 | lines 169–239 and 311–333 |
| PLN-14-002 | lines 241–256 |
| PLN-14-003 | lines 42–105 and 169–194 |
| PLN-14-004 | lines 311–333 |
| PLN-14-005 | lines 258–340 |
| REC-008 | lines 42–63 and 65–82 |

### Implementation consequences

1. Replace the graph support protocol with one private engine library.
2. Give each private module exactly one named invariant.
3. Replace callback ports with abstract owned state and sealed prepared changes.
4. Delete all six graph functors after their canonical replacements land.
5. Install a fixed 1,024-slot tombstone ring with O(1) insertion.
6. Move the complete stream bridge to `eta_signal_stream`.
7. Keep identity, diagnostic, timer, and lane arithmetic under separate owners.
8. Move tests from copied private algorithms to their invariant owners.
9. Delete `Owner_transaction`, `eta_signal_support`, and all replaced paths.
10. Keep the kernel as the sole graph factory and composition root.
