# Scheduler, demand, and topology model

Type: grilling
Status: resolved
Blocked by: 05, 06, 09

## Question

What scheduler, demand model, and edge representation give Eta Signal
change-proportional propagation and linear wide-node construction?

Decide dirty-frontier ownership, recompute order, necessity reference changes,
timer demand, dynamic-edge updates, static fan-in storage, dynamic edge removal,
and quiescent stabilization. State deterministic complexity contracts for each
operation.

The result must resolve F1, N4, and the engine part of F13. It must preserve the
transaction and invalidation model from
[Transaction and invalidation model](09-transaction-and-invalidation-model.md).
It must distinguish whole-node invalidation from repeated edge detachment while
an owner stays live.

## Answer

Eta Signal needs an incremental work ledger, a necessary-stale scheduler,
reference-counted demand, and indexed edge records. Stabilization must not use
the weak registry as a work index.

### Work admission and quiescence

One graph-owned work ledger stores counts for these classes:

- Actionable necessary-stale nodes in the scheduler.
- Observer initialization or pending delivery.
- Timer-source updates.
- Pending topology or demand transitions.
- Pending cleanup.
- Future private node-kind work.

Each subsystem changes only its own count. The ledger owns the total
zero-to-nonzero and nonzero-to-zero state.

`stabilize` checks this state in O(1). If every count is zero, it returns
success without entering `Planning`, advancing the snapshot count, scanning the
registry, scanning observers, traversing roots, or inspecting timers.

Quiescence means that all listed counts are zero. Source cutoffs alone do not
establish quiescence. Timer wakes, lifecycle changes, failed delivery, and
cleanup can create work without a source change.

The weak live-node registry remains a diagnostic and garbage-collection index.
Only explicit diagnostics or bounded maintenance can scan it.

### Necessary-stale scheduling

Each node stores `dirty`, `scheduled`, and committed queue-link state. A
clean-to-dirty transition adds the node to the graph-owned intrusive work deque
only when the node is necessary and not already scheduled.

Setting an already dirty node does not add another entry. Necessity loss removes
an unclaimed node through its queue links in O(1).

Planning does not mutate the committed deque. It reads that deque through an
attempt-local cursor and records each claimed node. New admissions enter a
separate attempt-local FIFO deque.

Dirty and scheduled bits use transaction-staged cells. A successful plan drains
every committed and attempt-local scheduler entry. Commit clears the committed
deque and publishes the staged bits.

Rollback discards the staged bits and attempt-local deque. The committed links
and their FIFO order never changed, so rollback needs no graph traversal or
queue reconstruction.

The scheduler uses an explicit-stack dependency-first traversal. Before it
recomputes a claimed node, it settles each necessary dirty dependency. It marks
the node complete only after all such dependencies complete.

A dynamic evaluator can discover a prospective dependency while its consumer
frame is active. The evaluator records the prospective edge, suspends that
frame, settles the dependency, and then resumes the consumer.

Each attempt gives a node one of `Unseen`, `Visiting`, or `Done`. Reaching a
`Visiting` prospective node reports `` `Cycle`` before topology publication.
Reaching `Done` reuses the attempt result.

A changed value marks each necessary dependent dirty. The dependent enters the
deque once. A cutoff that suppresses change does not propagate work.

This model does not require graph-wide heights. The committed graph is acyclic,
and ticket 09 validates each prospective topology before commit. A cycle found
in committed scheduling state is an internal invariant defect.

The work deque has deterministic FIFO admission. Dependency traversal follows
edge-slot order. These choices make defect order and diagnostics reproducible,
but they are not public value semantics.

### Incremental demand and timers

Each node stores one demand reference count:

```text
observer references + necessary-parent edge references
```

Each observer contributes one reference to its observed node. Each edge from a
necessary parent contributes one reference to its child. Parallel argument
edges contribute separate references.

A zero-to-one transition makes the node necessary. It adds references through
all dependency edges and schedules the node when it is stale. A one-to-zero
transition removes those references and removes unclaimed scheduled work.

Other count changes do not traverse the node dependencies. Shared descendants
therefore change necessity only at their own zero boundary.

Demand counts use checked arithmetic. Overflow is a typed graph error before
the related observer or topology mutation publishes. Counts cannot become
negative.

Observer registration and disposal apply these transitions while they hold the
graph lane. Registration makes committed dependencies necessary before it
returns. Disposal removes its reference and refreshes timer demand before it
returns.

Each edge stores whether it currently contributes one demand reference. The
prospective demand planner also stores this bit for every changed edge.

Observer deltas, edge additions, and edge removals seed one demand worklist. A
node zero crossing toggles the prospective contribution bit on each final
dependency edge and adds the exact child delta.

An added edge starts inactive and contributes once only when its prospective
parent is necessary. A removed active edge contributes one decrement before it
leaves the prospective graph.

The worklist runs until no count or edge-contribution bit changes. Thus each
final edge contributes exactly one reference if, and only if, its final parent
is necessary. Topology order cannot double-count or omit a reference.

Ticket 09 places the final counts and contribution bits in the same mutation
tape as topology.

A timer node stores desired lifecycle state separately from actual lifecycle
state. A zero-to-one transition sets desired state to running. A one-to-zero
transition sets it to stopped.

Any mismatch adds one timer lifecycle item to the work ledger. The demand module
does this without scanning live nodes or a timer registry.

Observer registration and disposal use the same finalizer-owned reconciliation
effect as stabilization. They commit demand first and then reconcile every
changed timer before returning.

A start failure cleans partial daemon state, leaves actual state stopped, and
keeps the running mismatch queued. A later graph effect retries it.

A stop invalidates the daemon generation before cancellation. The old daemon is
then logically stopped even when cancellation cleanup fails. That cleanup
failure is reported, but it cannot publish another timer value.

Timer daemon wakes enqueue timer-source work. They never call `stabilize`.

### Edge representation

The committed graph is a directed multigraph. Each constructor argument slot
has one edge, even when two slots reference the same child. The scheduler bit
still prevents duplicate node admission.

Each edge record contains:

- The parent and child nodes.
- Its fixed static slot or mutable dynamic slot.
- Its mutable slot in the child dependent vector.
- Its graph-local identity.

A static node stores an exact immutable edge array in argument order. Every node
stores its dependents in a geometrically grown dense vector.

A node with changing dependencies also stores a dense dynamic-edge vector.
Each dynamic edge records both mutable vector slots. Removal swaps the last
entry into the removed slot and updates that edge record.

Static construction allocates all edge records before publication. It appends
each record to the child dependent vector once. It performs no pairwise
membership search.

It also prepares every required dependent-vector capacity before publication.
An allocation defect therefore leaves the new node and all existing adjacency
unpublished.

Whole-node invalidation walks each owned edge once and removes it from the child
dependent vector by index. It then walks each dependent edge once. It does not
filter shrinking adjacency lists.

Repeated keyed removal uses the stored dynamic edge handle. Removing `k` keyed
children from a live owner performs O(k) adjacency removals.

Dynamic addition ensures vector capacity during planning. The sealed mutation
tape contains prepared inserts, swaps, slot updates, and any preallocated buffer
replacement. Commit performs no allocation or membership search.

The design does not add zero-, one-, or two-edge special cases. They add
representation branches without evidence that they improve Eta workloads.
Ticket 16 can establish a later performance need.

### Topology validation

Static construction validates each dependency before it creates the node.
Dynamic planning validates the complete prospective edge set.

A dynamic batch gathers every changed-edge root. One tri-color search validates
the union of their prospective reachable frontiers. The bound is O(Vr + Er)
for that union. Successful validation produces the prepared edge mutations for
ticket 09.

Removing an edge needs no cycle search. The implementation can retain
conservative scheduler metadata because dependency-first traversal does not use
height labels.

### Deterministic complexity contracts

The symbols have these meanings:

- `Vw` and `Ew` are nodes and dependency edges claimed by scheduler work.
- `Pc` is changed necessary-parent edges that propagate work.
- `Vd` and `Ed` are nodes and edges crossing a demand boundary.
- `d` is the complete degree of one invalidated node.
- `n` is static fan-in size.
- `k` is a count of changed dynamic edges.

| Operation | Required work |
|---|---|
| Fully quiescent stabilization | O(1) admission work and zero graph, root, observer, or timer scans. |
| Necessary clean-to-dirty transition | O(1) deque admission until the node is claimed. |
| Stabilize a dirty frontier | O(Vw + Ew + Pc) scheduler and propagation operations. |
| Demand zero-boundary change | O(Vd + Ed) reference operations. |
| Demand count change without a zero crossing | O(1). |
| Timer reconciliation | O(number of queued timer lifecycle items). |
| Static node with `n` argument edges | O(n) edge creation and amortized O(n) vector work. |
| Dynamic edge addition | O(1) amortized adjacency work, excluding prospective cycle search. |
| Dynamic edge removal | O(1) adjacency work. |
| `k` keyed removals from a live owner | O(k) adjacency work. |
| Whole-node invalidation | O(d) adjacency work. |
| Prospective cycle validation | O(Vr + Er) for the reachable validation frontier. |

No contract uses wall time. Ticket 16 must gate exact operation counts at
multiple scales and must reject a quadratic implementation.

### Transaction integration

Planning can mutate only its cursor, local deque, evaluator state, demand
worklist, and prospective topology. The committed deque, demand counts, edge
vectors, and timer state change through ticket 09's sealed mutation tape.

Rollback discards the attempt state and leaves committed work and edge slots
unchanged. Commit publishes prepared topology, demand, and scheduler state
before delivery starts.

Diagnostics read committed state. Diagnostic collection cannot repair
scheduler, demand, or topology state as a side effect.

### Deep-module ownership

| Module | Sole invariant owner |
|---|---|
| `Eta_signal_work` | Work-class counts and the O(1) quiescence decision. |
| `Eta_signal_scheduler` | Dirty and scheduled bits, unique deque admission, dependency-first traversal, and changed-parent propagation. |
| `Eta_signal_demand` | Demand reference counts, zero-boundary traversal, and desired timer state. |
| `Eta_signal_timer` | Actual timer lifecycle, generation invalidation, reconciliation, failure cleanup, and retry admission. |
| `Eta_signal_topology` | Edge identity, slot consistency, static arrays, dynamic vectors, indexed insertion and removal, and adjacency complexity. |
| `Eta_signal_commit_plan` | Prospective cycle validation and atomic publication of prepared scheduler, demand, and topology writes. |

The modules are private. Ticket 12 decides whether any first-party package seam
can submit declarative node plans without owning these invariants.

### Rejected alternatives

The design rejects graph-wide root reconstruction and timer-registry scans.
Those mechanisms reproduce F1 even when useful recomputation is narrow.

It rejects pairwise list membership for edges. It also rejects repeated list
filtering for dynamic removal.

It rejects a mandatory height heap. Dependency-first frontier traversal gives
the required order without rank repair after dynamic changes.

It rejects incidental weak-registry pruning inside stabilization. Maintenance
work must be explicit and separately bounded.

### Evidence

- Deterministic current-work measurements:
  [ticket 05](05-core-work-economics.md#answer).
- Required reference semantics and representation choices:
  [ticket 06](06-incremental-engine-reference.md#answer).
- Atomic mutation-tape contract:
  [ticket 09](09-transaction-and-invalidation-model.md#answer).
- Current list edge operations:
  `lib/signal/eta_signal_graph.ml:661-703`.
- Current graph-wide necessity and timer work:
  `lib/signal/eta_signal_graph.ml:1777-1865`.
- Current dirty and compute state:
  `lib/signal/eta_signal_graph.ml:705-786`.

### Census rows resolved here

Confirmed or retained evidence: `F01-021`, `F01-022`, `F01-023`, `F01-031`,
`F01-034`, `N04-009`, `N04-010`, `N04-014`, `N04-017`, `N04-018`,
`S02-001`, `PLN-06-004`, `PLN-07-002`, and `PLN-07-003`.

Accepted contracts: `F01-024`, `F01-025`, `F01-026`, `F01-027`, `F01-028`,
`F01-029`, `F01-033`, `F01-037`, `F01-038`, `F01-039`,
`F01-040`, `N04-012`, `N04-015`, `N04-019`, `N04-020`, `PLN-06-001`,
`PLN-06-002`, `PLN-07-001`, and `REC-012`.

Amended claims: `F01-030`, `F01-036`, and `N04-013`. Quiescence follows
actionable work, not all dirty state. Eta selects static arrays and indexed
dynamic vectors.

Rejected representation: `N04-021`. Small-edge specialization has no current
evidence.

### Resolution spans

| Census row | Answer span |
|---|---|
| `F01-021` | Lines 29-53 and 291-305. |
| `F01-022` | Lines 54-97. |
| `F01-023` | Lines 54-97 and 291-305. |
| `F01-024` | Lines 29-53 and 221-249. |
| `F01-025` | Lines 39-52 and 232-235. |
| `F01-026` | Lines 54-73. |
| `F01-027` | Lines 74-88. |
| `F01-028` | Lines 98-140. |
| `F01-029` | Lines 98-140. |
| `F01-030` | Lines 39-52. |
| `F01-031` | Lines 44-48. |
| `F01-033` | Lines 54-97 and 263-275. |
| `F01-034` | Lines 368-369. |
| `F01-036` | Lines 31-48 and 54-73. |
| `F01-037` | Lines 31-48 and 98-140. |
| `F01-038` | Lines 31-48 and 113-118. |
| `F01-039` | Lines 31-48. |
| `F01-040` | Lines 31-48. |
| `N04-009` | Lines 164-220 and 291-305. |
| `N04-010` | Lines 164-220 and 291-305. |
| `N04-012` | Lines 164-206 and 232-245. |
| `N04-013` | Lines 164-206 and 277-290. |
| `N04-014` | Lines 164-206 and 277-305. |
| `N04-015` | Lines 164-206 and 240-244. |
| `N04-017` | Lines 250-275. |
| `N04-018` | Lines 371-372. |
| `N04-019` | Lines 164-181. |
| `N04-020` | Lines 174-203. |
| `N04-021` | Lines 199-203 and 277-290. |
| `S02-001` | Lines 54-97 and 221-249. |
| `PLN-06-001` | Lines 29-97 and 221-249. |
| `PLN-06-002` | Lines 98-163. |
| `PLN-06-004` | Lines 368-369. |
| `PLN-07-001` | Lines 164-206 and 232-245. |
| `PLN-07-002` | Lines 250-275. |
| `PLN-07-003` | Lines 371-372. |
| `REC-012` | Lines 374-387. |

### Implementation consequences

The scheduler and demand replacement changes graph state, dirty propagation,
observers, timers, diagnostics, and model tests.

The topology replacement changes node records, every edge operation, DOT
generation, invalidation, and construction tests.

### Work instrumentation

The engine provides resettable private counters at the invariant owners. The
counters record:

- Work-ledger admission checks and state transitions.
- Scheduler admissions, claims, dependency visits, and propagation edges.
- Demand-reference operations and timer zero-boundary transitions.
- Static inserts, dynamic inserts, indexed removals, swaps, and invalidations.
- Prospective cycle-search node and edge visits.

The test seam reads and resets these counters while it holds the graph lane.
Public `stats` need not expose them. Ticket 12 owns the type-safe test seam, and
ticket 16 owns exact workloads and ceilings.
