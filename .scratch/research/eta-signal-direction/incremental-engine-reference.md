# Incremental engine reference

**Purpose:** record Jane Street Incremental evidence for Eta Signal design.

## Evidence scope

The primary `incremental` checkout at
`/home/ribelo/projects/github/incremental` is present at commit
`2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6`
(`v0.18~preview.130.100+614`). The primary `incr_map` checkout is present at
`/home/ribelo/projects/github/incr_map` at commit
`21c6bc602c75d57242b4c3e945da597f82c6280f`
(`v0.18~preview.130.106+341`). The audit records these same pins in
[its reference list](../eta-signal-incremental-audit/REVIEW.md#L7-L13).

The exact packed file named by the independent review,
`eta-signal-audit-gptpro-complete-20260804-100948.md`, is not present in this
worktree. The pinned `incr_map` checkout is present, so the keyed evidence is
not blocked. The independent review's summary is cross-check evidence, not a
replacement for the source.

## Mechanism findings

### Dirty propagation

`Node.is_stale` compares a node's `recomputed_at` value with each child's
`changed_at` value. It also handles variables, explicit stale marks, time
nodes, and invalid nodes.
[Node.is_stale and needs_to_be_computed](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/node.ml#L132-L198)

`Var.set` records a new set time and queues the variable watch when the watch
is necessary. A changed node records `changed_at`, then queues each necessary
parent once.
[State.set_var_while_not_stabilizing](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1276-L1302)
[State.maybe_change_value](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L984-L1055)

**Owned invariant:** `needs_to_be_computed` means “necessary and stale”.
Necessary stale nodes, and only those nodes, are in the recompute heap. A node
value change reaches all necessary parents.
[Node.invariant](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/node.ml#L292-L305)
[Incremental stabilization invariants](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L250-L284)

`Node` owns change timestamps and the stale predicate. `State` owns propagation
and heap admission. `Recompute_heap` owns pending-work uniqueness and minimum
height selection. A cutoff owns whether a recomputed value counts as changed.

### Recompute ordering

The public reference contract uses a height-ordered heap. Every parent has a
greater height than each child. Stabilization removes the smallest height,
recomputes that node, and queues changed parents.
[Stabilization contract](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L109-L129)
[Recompute_heap](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/recompute_heap.ml#L98-L187)

`State.add_parent` inserts an active necessary-parent edge before it checks the
height relation. When the relation fails, `Adjust_heights_heap` raises ancestor
heights. It detects a cycle if the traversal reaches the original child.
[State.add_parent](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L590-L608)
[Adjust_heights_heap.adjust_heights](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/adjust_heights_heap.ml#L123-L203)

The check runs after each edge insertion, not after a batch of graph changes.
An exception does not roll back the inserted edge.
[Cycle-check timing](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L296-L311)

**Owned invariant:** after a successful edge addition, every parent has greater
height than its children. `Adjust_heights_heap` owns height repair and cycle
detection. It does not own atomic edge rejection. `Recompute_heap` owns the
execution order.

An Expert node stores an inactive dependency without a necessary-parent edge.
If the Expert node is necessary, `add_dependency` routes the parent edge through
the same cycle check.
[State.Expert.add_dependency](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L2039-L2063)

The heap, integer heights, height cap, and direct-recompute shortcuts are
representation or performance choices. Eta needs dependency-before-consumer
semantics, but it does not need this height representation.

### Necessity transitions

`Node.is_necessary` is true when a node has a necessary parent, an observer, a
`Freeze` kind, or `force_necessary`.
[Node.is_necessary](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/types.ml#L482-L491)

When a node becomes necessary, `State.became_necessary` adds parent pointers
from its children, computes heights, and admits stale nodes to the heap. When
it becomes unnecessary, `State.became_unnecessary` removes child edges,
lowers its height, and removes it from the heap.
[State.became_necessary](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L535-L588)
[State.became_unnecessary](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L361-L387)

Observer creation and disposal change demand only at stabilization start.
New observers are linked before disallowed observers are unlinked. This avoids
graph changes while user functions run.
[State.add_new_observers and unlink_disallowed_observers](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1130-L1242)
[State.stabilize_start](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1311-L1319)

**Owned invariant:** parent edges exist exactly for necessary parents. Demand
transitions add or remove the full necessary descendant frontier. `State` owns
the transition. `Internal_observer` owns observer lifecycle state.

The parent count, observer list, `Freeze` special case, and `force_necessary`
flag are representation details. The semantic requirement is demand-gated
computation with complete edge cleanup.

### Edge storage

Ordinary nodes store one parent in `parent0` and more parents in a packed
array. Child and parent indexes make removal a swap-with-last operation.
Capacity grows geometrically.
[Node edge representation](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/types.ml#L418-L448)
[Node.add_parent and remove_parent](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/node.ml#L540-L618)

`Expert` nodes use packed `edge` records. Each edge stores a child, an
`on_change` callback, and a mutable index. The node stores `force_stale` and a
count of invalid children. Removing an edge swaps the last edge and updates
both index tables.
[Expert edge type](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/expert.ml#L5-L39)
[Expert edge operations](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/expert.ml#L88-L179)
[State.Expert edge mutation](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L2039-L2098)

**Owned invariant:** every live graph edge has one consistent child index,
parent index, and dependency identity. `Node` owns ordinary adjacency.
`Expert` owns dynamic edge callbacks and invalid-child accounting.

The packed arrays, intrusive links, and swap removal are representation
choices. Eta must preserve edge identity, cleanup, and demand semantics without
copying these data structures by default.

### Bind and scope invalidation

`bind` creates a `Bind_lhs_change` node and a `Bind_main` node. The RHS runs
inside a `Scope.Bind` scope. The scope keeps a singly linked list of nodes
created while the RHS runs.
[Bind construction](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1535-L1558)
[Scope.add_node](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/scope.ml#L19-L44)
[Bind state](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/bind.ml#L8-L42)

The height constraint computes the LHS before nodes created by the RHS.
When the LHS changes, `Bind_lhs_change` replaces the RHS edge, invalidates the
old RHS scope by default, and propagates invalidity upward. The configuration
that preserves old RHS nodes by rescoping exists only as a compatibility
escape. The default is invalidation.
[Bind contract](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L141-L211)
[State.recompute Bind_lhs_change](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L670-L729)
[Invalidation propagation](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L394-L528)
[Default bind invalidation](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/config_intf.ml#L4-L10)
[Default configuration](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/config.ml#L3-L6)

**Owned invariant:** under the default configuration, a node from an old bind
RHS cannot be recomputed after its LHS changes. The bind scope owns RHS
membership. `State` owns invalidation closure. The compatibility configuration
replaces this invariant with rescoping. `Node.should_be_invalidated` decides
where invalidity stops for switchable nodes.
[Node.should_be_invalidated](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/node.ml#L232-L277)

`run_with_scope` restores the current scope when the RHS function raises. This
is local scope cleanup, not graph rollback.
[State.run_with_scope](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L617-L634)

### Keyed removal and external dynamic nodes

`incr_map` implements per-key `mapi'` as a separate library over
`Incremental.Expert`. Its `generic_mapi'` keeps the previous input map,
per-key nodes, and output accumulator.
[incr_map.Generic.generic_mapi'](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L753-L847)

The keyed diff owns this sequence:

1. For an unequal existing value, call `E.Node.make_stale`.
2. For a removed key, remove its output dependency, remove its accumulator
   entry, and call `E.Node.invalidate`.
3. For a new key, create its node in the current scope and attach the input and
   output dependencies.

The `Expert` node owns dynamic dependency edges and callback delivery. The
per-key node owns one key's computation. The diff state owns key membership and
the previous map. The accumulator owns the current output map.

**Owned invariant:** a removed key has no output dependency and its per-key
node is invalid. A changed key becomes stale without rebuilding unrelated
keys. A new key has one complete dependency set.

This is the required keyed behavior. `Map.fold_symmetric_diff`, mutable
accumulators, the public `Expert` API, and the current-scope construction are
representation choices. The audit and independent review use this code as
evidence that a keyed node kind can live outside the engine. They do not make a
public `Expert` API an Eta requirement.
[Independent review, F2](independent-review.md#L96-L127)
[Audit keyed-map evidence](../eta-signal-incremental-audit/REVIEW.md#L295-L317)

### Commit boundaries and exception regions

Incremental has no transactional graph commit. `stabilize` starts demand
changes, recomputes nodes in place, then runs `stabilize_end`.
[State.stabilize](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1311-L1382)

`stabilize_end` increments the stabilization number, applies variable sets
that occurred during stabilization, builds update values, and runs handlers.
Variable sets therefore enter the next stabilization. Node values and graph
edges already changed during the recompute pass.
[State.stabilize_end](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1321-L1363)
[State.set_var during stabilization](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1289-L1302)

The one exception region covers start, recomputation, deferred sets, and
handlers. Any exception stores `Stabilize_previously_raised`. Later
stabilizations raise again.
[State.raise_during_stabilization](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1365-L1382)
[Stabilization error contract](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L71-L76)

`run_with_scope` has a narrow restoration region. It does not restore node
values, edges, observers, or the recompute heap.

**Owned invariant:** after a successful `stabilize`, all necessary stale nodes
are computed and deferred variable sets wait for the next cycle. The reference
chooses permanent failure after an exception instead of rollback.

### Observer delivery order

`handle_after_stabilization` deduplicates nodes on a LIFO stack. At the end of
stabilization, each node produces one internal update. Those updates enter a
second LIFO stack, which runs in reverse collection order.
[State.handle_after_stabilization](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L352-L359)
[State.stabilize_end update collection](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1337-L1360)

Within a node, direct handlers run before observer handlers. Handler lists and
observer lists are newest-first because registration links at the head.
[Node.run_on_update_handlers](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/node.ml#L462-L490)
[Observer handler registration](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/internal_observer.ml#L131-L145)
[Observer linking](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1217-L1239)

`On_update_handler.run` suppresses duplicate transitions and records
`Necessary`, `Changed`, `Invalidated`, or `Unnecessary`. The public observer
wrapper rejects `Unnecessary`, while the public contract promises at most one
callback per stabilization and does not promise dependency order.
[On_update_handler.run](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/on_update_handler.ml#L14-L65)
[Public observer contract](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1473-L1506)
[Public observer wrapper](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental.ml#L139-L178)

**Owned invariant:** one handler receives at most one valid update per
stabilization, subject to its prior update state. The stacks and linked lists
own execution order. That order is an implementation consequence, not a
topological observer law.

## Semantic requirements versus representation choices

### Requirements supported by the reference

1. Compute only necessary, stale nodes.
2. Propagate a real value change to every necessary dependent.
3. Compute dependencies before consumers.
4. Add and remove demand edges as observers and parents change.
5. Under the default configuration, invalidate all nodes owned by an obsolete
   bind RHS.
6. Remove keyed output edges and invalidate removed keyed nodes.
7. Deliver observer updates after graph recomputation, with at most one valid
   update per handler per stabilization.
8. Keep every successfully stabilized necessary graph acyclic.

Eta can adopt these requirements only after adding its own effect, cancellation,
transaction, and lifecycle rules.

### Representation choices shown by the reference

- stabilization timestamps instead of per-node dirty epochs
- per-height arrays instead of a work queue or topological frontier
- packed parent arrays with swap removal
- intrusive scope lists for bind RHS membership
- `Expert` edge records with synchronous callbacks
- mutable keyed accumulators and `Map.fold_symmetric_diff`
- finalizer-driven observer disposal
- LIFO stacks for update delivery
- permanent graph poisoning after an exception
- per-edge post-insertion cycle checks without rollback

These choices do not define incremental semantics. Eta can choose other
representations when it preserves the requirements above.

## Mechanisms Eta must not copy

- **Permanent exception poisoning.** Incremental turns every stabilization
  exception into `Stabilize_previously_raised`. Eta has typed effect failures,
  cancellation, and an explicit recovery or disposal contract. It must not
  copy this global lifecycle.
- **In-place recomputation without a commit plan.** Incremental exposes changed
  node values and edges before handler delivery and has no rollback. Eta needs
  an explicit transaction and publication boundary. N1 and N2 prove that the
  current implementation does not enforce this boundary universally
  ([atomic phase entry](../../../docs/wayfinder/eta-signal-direction/issues/02-atomic-phase-entry.md#answer),
  [keyed bind invalidation](../../../docs/wayfinder/eta-signal-direction/issues/03-keyed-bind-invalidation.md#answer)).
- **Synchronous `Expert` callbacks as user effects.** `Expert` callbacks run
  during graph recomputation. Eta observers can run effectful, cancellable,
  resource-owning work. Eta must deliver them through its effect lifecycle.
- **Finalizers as the correctness boundary.** Incremental uses observer
  finalizers to remove demand. Eta resource cleanup and scope invalidation must
  not depend on finalizer timing.
- **Public `Unnecessary` observer updates.** Incremental has this internal
  node-handler state, but an active observer itself keeps its node necessary.
  Eta's observer and stream lifecycle uses typed disposal and invalid-scope
  outcomes instead
  ([independent review, F4](independent-review.md#L163-L210)).
- **Incidental LIFO callback order.** The reference does not promise a
  dependency order. Eta must define an order that remains valid when callbacks
  suspend, fail, or cancel.
- **The broad mutable `Expert` surface.** `incr_map` proves that the surface
  supports an external keyed library. It does not justify exposing arbitrary
  graph mutation in Eta. A future Eta SPI must keep scheduling, invalidation,
  transaction, and lifecycle ownership inside the engine.

## Checks and limits

I read the Wayfinder map before this ticket. I read the ticket, the independent
review, and the audit's reference-pin and keyed-map sections. I inspected the
primary source files listed above and verified the source checkout commit
identities from their local branch refs. I did not change production code or
tests, and I did not run a build because this work changes research documents
only.

The named packed audit file is absent. The independent review records different
Eta commit labels for the packed code and probe baseline
([review limits](independent-review.md#L7-L16)). Ticket 01 later proved that the
relevant Signal trees have identical Git objects at both commits
([repository evidence](../../../docs/wayfinder/eta-signal-direction/issues/01-complete-repository-evidence.md#answer)).

The pinned source checkout used here is
`2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6`, as recorded by the audit. No
requested `incr_map` fact is blocked because its pinned primary checkout is
present. No semantic contradiction appeared between that source and the
available audit summary. The source shows terminal, non-transactional exception
behavior. Eta must preserve its different lifecycle contract instead of copying
that behavior.
