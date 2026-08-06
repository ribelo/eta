# Dynamic topology and keyed work

Date: 2026-08-06

## Scope

This report answers the
[Dynamic topology and keyed work](../../../docs/wayfinder/eta-signal-execution-model/issues/08-dynamic-topology-and-keyed-work.md)
ticket.

The report selects the private topology model for `bind`, dynamic scopes,
demand, and keyed membership.

The model extends these selected parts:

- the direct value kernel from
  [Value-propagation kernel](value-propagation-kernel.md)
- the sparse undo journal from
  [Failure and rollback model](failure-and-rollback-model.md)
- the generation-safe arena from
  [Node identity and index lifecycle](node-identity-and-index-lifecycle.md)
- the typed node representation from
  [Generic typed value storage](generic-typed-value-storage.md)

The durable evidence is in
[`dynamic-topology-probe/`](dynamic-topology-probe/).
The probe is throwaway code and does not change the production Signal engine.

Effect, Eio integration, observer delivery, and timer execution remain outside
the candidate.

## Answer

Use owner-local shadow capsules for all dynamic owners.

A bind owner has one capsule for its source, branch, scope, edge, and demand.
A keyed owner has one capsule for its input root, child root, output root, and
affected children.

Each capsule contains the committed state and one candidate state.
An intrusive chain identifies each affected owner once.

An active pass reads the candidate state.
A quiescent pass reads the committed state.

Commit changes one pass verdict and enters `Cleanup_pending`.
It does not visit an owner, child, edge, scope, or journal entry.

Affected-only cleanup makes candidate state canonical.
It also invalidates replaced scopes and clears all pointer-bearing capsule
fields.

Rollback walks only affected capsules.
It restores committed roots, edges, demand, and scopes before tentative nodes
disappear.

The selected module treats a bind as a one-child family.
It treats keyed membership as a multi-child family.

The adapters differ only in source comparison, persistent map operations,
child construction, and retained-data updates.

## Binding behavior

The binding oracle is
[`binding-signal-behavior.md`](binding-signal-behavior.md).
Issue 08 inherits these rows.

| Row | Required observation |
|---|---|
| SB10 | A failed structural pass preserves committed values and topology. Source work stays retryable. |
| SB12 | A bind switch invalidates the old branch only after success. Failure preserves its identity and scope. |
| SB13 | Demand release stops unnecessary ownership. Reactivation computes through a fresh necessary path. |
| SB16 | Dynamic invalidation finishes owned observers with `Invalid_scope`. |
| MB06 | Continuous key presence preserves one child incarnation. Removal and re-entry create different incarnations. |
| MB08 | Affected changes patch one output root. A no-op preserves the exact root. |
| MB09 | Failure preserves child identity, scope validity, data, and all committed roots. |
| MB10 | Keyed work stays proportional to changed input and selected children. |

The probe observes branch identity, scope validity, demand, map-root identity,
child identity, output values, and exact work counts.

It does not execute public observers or timers.
Therefore, the probe does not prove complete SB13 or SB16 compliance.

## Design It Twice

The comparison used four private interfaces.

### A. Chronological inverse-action journal

Candidate A exposes operations such as edge insertion, edge removal, scope
retirement, root replacement, and demand adjustment.

Each mutation appends an inverse action.
Rollback replays actions in reverse order.

This model is flexible and fast.
The dynamic-switch prototype allocates 10 words and takes approximately 6.47
nanoseconds.

The interface is shallow.
Bind and keyed adapters must know the legal action sequence and rollback order.

The deletion test moves the structural protocol back into both adapters.
This candidate therefore loses on module depth.

### B. Generic structural cells

Candidate B exposes typed structural cells plus node, scope, edge, demand, bind,
and keyed operations.

First writes save old structural values.
One shared journal restores the cells.

This model supports future structural capabilities.
Its interface also permits many illegal edit sequences.

Callers still coordinate cell writes with edge and scope operations.
The model has less locality than a semantic owner operation.

The large interface and protocol knowledge make this candidate the least deep
qualifying mutable design.

### C. Owner-local shadow capsules

Candidate C exposes direct `switch` and `reconcile` operations.

The module owns candidate scopes, dynamic edges, demand transfer, keyed
continuity, output patches, rollback, and cleanup.

A capsule groups all state for one semantic owner.
Illegal partial transitions are not available through the interface.

The dynamic-switch prototype allocates 12 words and takes approximately 11.1
nanoseconds.

This result is slower than candidate A.
Both results pass the dynamic allocation and wall-time gates.

The acceptance matrix ranks module depth before allocation and wall time.
Candidate C wins because its interface hides the complete structural protocol.

### D. Immutable whole-topology replacement

Candidate D creates a prospective topology root for each structural pass.

Rollback discards that root.
Commit changes the accepted root in O(1).

One edit copies work proportional to live topology.
The probe copies 100,000 entries for one edit with 100,000-entry ballast.

This candidate fails the affected-work gate.
It is not eligible.

### Comparison

| Property | A action journal | B structural cells | C owner capsules | D immutable topology |
|---|---|---|---|---|
| Caller operation | Low-level edits | Cells and edits | `switch` or `reconcile` | Replace root |
| Illegal partial state | Caller can create it | Caller can create it | Hidden | Hidden |
| O(1) commit | Yes | Yes | Yes | Yes |
| Rollback work | O(actions) | O(first writes) | O(affected owners) | O(1) discard |
| Cleanup work | O(actions) | O(first writes) | O(affected owners) | Retained old root |
| One-edit work with ballast | O(affected) | O(affected) | O(affected) | O(live) |
| Dynamic words | 10 | Not selected | 12 | Depth-dependent |
| Interface depth | Low | Low | High | Medium |
| Verdict | Rejected | Rejected | Selected | Ineligible |

## Selected private module

Production names can differ.
The semantic interface has this shape:

```ocaml
module Dynamic_topology : sig
  type t
  type pass
  type cleanup
  type scope
  type node

  type ('source, 'value) bind_site
  type ('key, 'data, 'output, 'input, 'children, 'output_map) keyed_site
  type ('key, 'data, 'output) child

  val begin_pass : t -> Node_lifecycle.pass -> pass

  val switch :
    pass ->
    ('source, 'value) bind_site ->
    source:'source ->
    select:(scope -> 'value node) ->
    value:'value

  val reconcile :
    pass ->
    ('key, 'data, 'output, 'input, 'children, 'output_map) keyed_site ->
    input:'input ->
    output_map

  val note_child_dirty :
    ('key, 'data, 'output, 'input, 'children, 'output_map) keyed_site ->
    ('key, 'data, 'output) child ->
    unit

  val commit : pass -> cleanup option
  val cleanup : cleanup -> unit
  val rollback : pass -> unit
end
```

The installed public interface stays unchanged.
The public execution adapter continues to expose `set` and `stabilize`.

`bind_site` is a singleton stable family.
Its source equality decides whether the branch stays or changes.

`keyed_site` receives persistent map operations from `eta_signal_map`.
This adapter preserves the optional package boundary.

The dirty-child operation takes a child incarnation.
It does not take only a key.

A stale listener therefore cannot select a replacement child with the same
key.

## Capsule invariants

Each dynamic owner has one committed state and at most one candidate state.

Each owner enters the affected chain at most once in one pass.
Each keyed child enters its dirty chain at most once.

Long-lived node references use a slot and generation.
Active capsules can use pass-local slots after handle validation.

Current-pass retired slots remain in quarantine.
No candidate can reuse them before cleanup or rollback finishes.

Each dynamic edge has reciprocal adjacency slots.
Removal repairs at most one moved slot at each endpoint.

An owner-local index finds each dynamic edge.
Removal never searches an adjacency vector.

Each child incarnation contains these items:

1. the stored key representative
2. one scope
3. one stable data source
4. one data signal
5. one output signal
6. one dynamic dependency edge
7. one dirty-listener identity

Continuous presence preserves the complete incarnation.
Removal invalidates it after publication.

Re-entry creates a fresh generation and scope.
A stale handle cannot resolve the replacement.

Candidate keyed roots start from their committed roots.
Input events and selected child changes patch only affected paths.

A suppressed data update keeps the committed data baseline.
A physical output no-op keeps the exact committed output root.

## Pass ordering

Preflight performs all fallible structural work.
It validates scopes, capacity, counters, demand, edge uniqueness, and cycles.

After preflight, commit changes the pass verdict.
This change makes every candidate capsule effective in O(1).

A structural commit enters `Cleanup_pending`.
No pass, allocation, or rollback can cross this fence.

Cleanup runs before callbacks and timer work.
It visits only affected capsules and topology entries.

For keyed work, cleanup detaches removals before it installs additions.
It invalidates each removed scope after detachment.

Cleanup then makes candidate roots and incarnations canonical.
It clears every pointer-bearing inactive capsule field.

Rollback uses this order:

1. Node lifecycle restores retired node pointers.
2. Dynamic topology restores roots, scopes, edges, listeners, and demand.
3. The sparse value journal restores each first-written value.
4. Node lifecycle discards tentative nodes.
5. Dynamic topology clears pointer-bearing capsule fields.

This order keeps every restored topology reference resolvable.

The value journal retains only immediate slot integers.
A removed node leaves its topology capsule during cleanup or rollback.

## Demand and invalidation

Demand propagation occurs only when a reference count crosses zero.

A demanded bind switch transfers one demand reference from the old branch to
the candidate branch.

Rollback transfers that reference back.
No timer or observer action becomes public before commit.

Cleanup releases the old scope.
The observer and timer adapters consume the resulting invalidation events.

Scope ownership supplies affected-only invalidation.
The module does not search unrelated graph dependents.

## Keyed work

Input reconciliation uses the persistent map diff from `eta_signal_map`.
Comparator equality remains key identity.

Retained data changes update the existing child source.
They do not rebuild the child.

Additions create tentative child scopes.
Removals keep old children valid until successful cleanup.

Child-only work enters through the exact dirty child.
It performs no input comparison and emits no input diff event.

The probe checks this path at 1,000, 10,000, and 100,000 keys.
Each case visits one selected child and one cleanup entry.

Mixed rollback updates one child, removes one child, and adds one child.
It then restores all three committed roots by physical identity.

The retained and removed children keep their identities.
The tentative child becomes invalid.

## Static path

Static nodes keep direct dependency arrays.
A static pass does not enter `Dynamic_topology`.

The probe checks zero topology commits, cleanup visits, and scope visits at
depths 1, 10, and 100.

Issue 16 measured the inherited static path at 4 words for all three depths.
The capsule design adds no operation to that path.

## Measurement protocol

The authoritative results are in
[`summary.csv`](dynamic-topology-probe/summary.csv).
The complete samples are in
[`results.csv`](dynamic-topology-probe/results.csv).

The release build used the OxCaml Nix shell.
Each workload ran in a fresh process pinned to CPU 2.

Calibration started with one operation.
It doubled the count until 0.5 seconds or 16,777,216 operations.

Each process reported nine samples.
The run used three complete comparison pairs.

The allocation formula was:

```text
minor words + major words - promoted words
```

Setup, graph construction, warm-up, the final read, and teardown stayed outside
the measured operation.

One dynamic operation changed one selector and completed one structural pass.

One keyed operation changed one input binding, membership, or child source.
It then completed one structural pass.

The matched Incremental rows use no update callback.
Their allocation results equal the frozen raw references.

## Prototype measurements

The table reports the candidate allocation and its largest wall-time ratio
across three pairs.

| Workload | Size | Candidate words | Allocation gate | Largest wall ratio |
|---|---:|---:|---:|---:|
| Dynamic switch | 3 nodes | 12 | 51.6 | 0.092 |
| Keyed data | 10,000 keys | 160 | 216 | 0.402 |
| Keyed data | 100,000 keys | 208 | 273.6 | 0.405 |
| Keyed membership | 10,000 keys | 269 | 412.2 | 0.364 |
| Keyed membership | 100,000 keys | 323 | 520.2 | 0.364 |
| Keyed child | 10,000 keys | 82 | 93.6 | 0.724 |
| Keyed child | 100,000 keys | 106 | 122.4 | 0.772 |

Every allocation result passes its frozen raw gate.
No result changes with unrelated graph ballast.

The public Eta edge row uses a three-node demanded bind.
One operation replaces its branch and cleans the old dynamic scope.

The reference is current production code from pinned Eta revision
`d04d6e2bedc87ab22326af5cc03c339406177a67`.

The capsule row uses the private raw seam.
The Eta row uses the complete public Effect and Eio seam.

The largest observed private-to-public wall ratio is 0.002.
The allocation ratio is also 0.002.

This seam difference makes the edge ratio context, not an integrated
acceptance result.
Issue 11 owns the integrated finalist comparison.

## Independent checks

The checks cover these discriminating cases:

1. bind rollback preserves the incumbent identity and scope
2. successful bind cleanup invalidates the old scope
3. demanded bind replacement transfers exactly one demand reference
4. keyed retained data preserves child identity
5. keyed removal rollback preserves all committed roots
6. keyed removal and re-entry create a fresh incarnation
7. mixed keyed rollback restores three roots by physical identity
8. child-only work visits one child with zero input events
9. commit records two fixed semantic steps for 0, 1, 4, and 1,000 affected children
10. cleanup visits exactly the affected child count
11. the action journal restores a branch through inverse replay
12. immutable topology replacement copies all ballast entries
13. static passes record zero topology work at depths 1, 10, and 100

The immutable control uses ballast sizes 1, 1,000, and 100,000.
One edit copies the complete array in every case.

## Rejections

Reject the action journal as the external private seam.
Its faster switch does not offset its shallow mutation interface.

The selected capsule implementation can use small internal action records for
adjacency repair.
Those records remain hidden inside the semantic owner operation.

Reject generic structural cells as the main interface.
They expose too many legal and illegal edit combinations.

Reject immutable whole-topology replacement.
One small edit performs work proportional to live topology.

Do not split bind and keyed lifecycle into separate modules.
That split duplicates scope, edge, demand, rollback, and cleanup rules.

Do not identify dirty keyed children by key alone.
A stale listener can then select a new incarnation.

Do not run cleanup after callbacks.
Callbacks must observe a complete committed topology.

## Limits

The candidate uses integer values and `Stdlib.Map`.
It does not prove generic typed value storage.

The candidate models direct edge counts.
It does not implement the complete production adjacency representation.

The probe does not execute nested bind depths 8 and 64.
The integrated finalist must run the frozen frontier manifests.

The probe does not execute public observer invalidation or timer shutdown.
Issues 10 and 11 must verify those adapters.

The probe does not implement Effect, lane serialization, Eio, cancellation, or
multi-domain ownership.

The Eta edge row compares different seams.
It cannot replace the integrated public comparison.

## Decision

Select owner-local shadow capsules.

Keep one semantic structural module for bind and keyed owners.
Give callers direct `switch`, `reconcile`, and dirty-child operations.

Use a pass verdict for O(1) publication.
Run affected-only canonical cleanup before callbacks and timer work.

Keep scope, edge, demand, root, and incarnation rollback inside this module.
Use the node-lifecycle three-phase rollback order.

Keep static dependency arrays outside the module.
Static stabilization does not enter a capsule.

Use generation-safe long-lived handles.
Use pass-local slots only after handle validation.

Clear every pointer-bearing capsule field during cleanup or rollback.
Never scan the complete graph for structural repair.

The allocation and matched wall-time rows pass.
The integrated public edge row remains provisional until issue 11.
