# Observer delivery contract

Type: grilling
Status: resolved
Blocked by: 04, 06, 09, 10

## Question

What observer delivery order does Eta Signal promise?

Choose between deterministic identity order and deterministic topological order.
Define same-signal ordering, unrelated-root ordering, dynamic-bind changes,
event collection, fail-fast delivery, retries, coalescing, disposal, and the
snapshot visible to every callback.

The relation must be a total order. If dependency order is public law, the
design must compute one delivery plan instead of using pairwise reachability.
Resolve N3 and the observer-order claims in the current PRD.

## Answer

Eta Signal promises deterministic topological callback delivery. Every callback
for a dependency runs before every callback for its transitive consumer.

This order is a public law because observer effects can interact. Identity-only
order is total, but it makes graph composition irrelevant to effect order and
provides less consumer leverage.

### Candidate event collection

The engine keeps an observer-work set instead of scanning the observer registry.
These events add an observer once:

- Observer registration awaiting initialization.
- A changed stabilized value.
- A pending delivery from an earlier failure or interruption.

Disposal or scope invalidation removes the observer from this set. One observer
has at most one candidate event in one stabilization.

After pure recomputation, the planner reads each candidate from the final
prospective snapshot. It computes the observer's latest current value and its
coalesced update before commit.

The sealed commit plan contains the candidate events and final topology. Commit
publishes observer current values and marks each selected delivery pending.
Callback code does not run during collection or commit.

### One topological delivery plan

The planner groups candidate events by observed signal. It then traverses the
union of graph dependencies reachable from those signal groups.

Edges point from a dependency to its consumer for this plan. A Kahn-style plan
computes indegrees once. It never compares two observers with pairwise
reachability.

The planner repeatedly performs these steps:

1. Process every ready graph node without a candidate event.
2. Add newly ready candidate groups to a priority queue.
3. Select the group with the smallest observer identity.
4. Emit all events in that group by ascending observer identity.
5. Release its graph dependents and repeat.

Processing all ready hidden nodes computes the closure between candidate groups.
Thus, the priority queue contains exactly the event groups that are ready in
the collapsed observer precedence graph.

The resulting relation is total:

- Transitive dependencies precede consumers.
- Observers on the same signal use ascending observer identity.
- Ready unrelated signal groups use their smallest observer identity.
- Remaining ties use signal identity, then observer identity.

The planner uses the topology that ticket 09 will commit. A bind switch therefore
orders the selected new dependency before the bind observer. The retired branch
does not constrain delivery.

An unexpected cycle rejects planning with `` `Cycle``. Successful committed
topology is already acyclic, so this check also guards internal corruption.

### Snapshot and callback semantics

All callbacks in one plan observe the same committed pure snapshot. An earlier
callback cannot change the snapshot seen by a later callback.

Source updates from callbacks enter ticket 10's work ledger. They become visible
only after a later explicit stabilization.

`Observer.read` during a callback returns the current value from the committed
snapshot. Reads do not force recomputation.

`Var.value` remains the latest accepted source-state read. It can reflect a set
from an earlier callback, but that set is not part of the committed derived
snapshot. Derived observers publish it only after a later stabilization.

An observer registered during delivery belongs to a later stabilization. Its
callback cannot enter the active plan.

### Delivery cursor

Each observer stores:

- The last successfully delivered value, if one exists.
- Its latest committed current value.
- At most one pending update and delivery token.
- A pending or running delivery state.

Collection coalesces against the last successfully delivered value. A never
delivered observer receives `Initialized latest`.

A previously delivered observer receives `Changed { old_value; new_value }`.
`old_value` is the last successfully delivered value, and `new_value` is the
latest committed value.

If both values satisfy the observer cutoff, collection acknowledges the pending
delivery without a callback. Intermediate failed values are not delivered.

A newer stabilization replaces an unclaimed pending target with the latest
coalesced target. It does not create a second pending event.

### Fail-fast execution and retry

Delivery runs events sequentially in the frozen plan. The first callback typed
failure, defect, or interruption stops the remaining plan.

Before callback construction, the event changes from pending to running. A
protected finalizer then makes one terminal decision.

Ordinary callback success records a successful outcome. Its protected finalizer
changes the current running token to delivered under the graph lane.
Construction failure, typed failure, defect, or interruption returns running
state to pending. A later stabilization can retry that observer.
A sealed delivery capability can acknowledge after a durable send or terminal drop.
That graph-lane change linearizes delivery immediately. Later callback failure or
interruption cannot return the acknowledged event to pending.

Lifecycle finish competes with acknowledgement through the same graph lane. The
first lane mutation wins:

- If acknowledgement wins, the event is delivered before later disposal.
- If disposal wins, it removes the cursor and the finalizer becomes a no-op.
- If failure release wins, the active observer keeps one pending event.

A callback already running is not cancelled by disposal. Its result cannot
restore a disposed cursor or create a retry.

Events before failure and directly acknowledged events remain acknowledged.
Unacknowledged failed and later active events remain pending. The next plan
recomputes their order from the latest committed topology.

Delivery is at least once while the observer remains active, until
acknowledgement. Lifecycle finish ends that guarantee. An ordinary callback can
run again after external work followed by failure or interruption.

Consumers must use idempotent effects or external deduplication when repeated
work matters.

### Disposal and invalidation

Each event checks observer lifecycle and token state before claim, construction,
callback execution, and acknowledgement.

Disposal before claim removes pending state and skips the callback. Disposal
during a running callback follows the lane race above. It always prevents later
callback delivery.

Dynamic-scope invalidation happens during pure commit. An invalidated observer
is absent from the delivery plan and reports `Invalid_scope` through reads.

Disposal and invalidation run finish hooks exactly once through ticket 09's
cleanup ledger. A skipped event cannot retain demand.

### Complexity contract

Let `C` be candidate observers. Let `Vu` and `Eu` be nodes and edges in the union
of their dependency closures.

Event collection takes O(C). Topology collection and indegree construction take
O(Vu + Eu). Ready-group priority operations take O(C log C).

Delivery takes O(C) lifecycle checks and callback attempts. The algorithm does
zero pairwise dependency searches and does not scan unrelated observers.

Ticket 16 must count candidate visits, union node and edge visits, priority
operations, lifecycle checks, callback attempts, and acknowledgements.

### Deep-module ownership

| Module | Sole invariant owner |
|---|---|
| `Eta_signal_observer_plan` | Candidate uniqueness, final-topology traversal, the topological total order, and the frozen event sequence. |
| `Eta_signal_observer` | Lifecycle, current and delivered values, coalescing, delivery tokens, and pending or running cursor state. |
| `Eta_signal_observer_delivery` | Sequential fail-fast execution, finalizer decisions, lane-linearized acknowledgement, and release to pending. |
| `Eta_signal_commit_plan` | Atomic publication of observer current values and pending events with the graph snapshot. |
| `Eta_signal_atomic_pass` | Delivery start after commit and the pure-snapshot fence around every callback. |

### Rejected alternatives

The design rejects signal or observer identity as the primary order. It is
deterministic but cannot preserve dependency order.

It rejects the current pairwise comparator. Mixing reachability with identity
fallback is cyclic, and repeated depth-first searches are superlinear.

It rejects registration-list order and reference-library LIFO order. Both are
incidental container behavior.

### Evidence

- Executable N3 counterexample and policy controls:
  [ticket 04](04-observer-order-counterexample.md#answer).
- Reference observer behavior and non-contract ordering:
  [ticket 06](06-incremental-engine-reference.md#answer).
- Atomic publication and post-commit boundary:
  [ticket 09](09-transaction-and-invalidation-model.md#answer).
- Necessary-stale work and final prospective topology:
  [ticket 10](10-scheduler-demand-and-topology.md#answer).
- Current pairwise comparator:
  `lib/signal/eta_signal_graph.ml:808-825`.
- Current cursor and fail-fast runner:
  `lib/signal/eta_signal_observer.ml:242-388,429-578`.
- Current collection sort and registry scan:
  `lib/signal/eta_signal_observer.ml:783-859`.

### Census rows resolved here

Confirmed current defects: `N03-010`, `N03-011`, and `S09-001`.

Accepted topological contract: `N03-013`, `N03-015`, `N03-016`, `N03-017`,
`N03-018`, `PLN-05-001`, `PLN-05-002`, `Q03-001`, and `Q03-002`.

Retained delivery semantics: `N03-021`, `S10-001`, `S10-002`, and
`PLN-05-004`.

Amended sequencing: `N03-020` and `PLN-05-003`. Ticket 10 now supplies the
final prospective topology before observer planning.

Rejected identity-order consequence: `N03-014`.

### Resolution spans

| Census row | Answer span |
|---|---|
| `N03-010` | Lines 22-27, 213-214, and 221-226. |
| `N03-011` | Lines 77-79, 213-214, and 221-226. |
| `N03-013` | Lines 22-27 and 202-203. |
| `N03-014` | Lines 202-203. |
| `N03-015` | Lines 58-75. |
| `N03-016` | Lines 54-56 and 181-185. |
| `N03-017` | Lines 70-75. |
| `N03-018` | Lines 22-23 and 70-75. |
| `N03-020` | Lines 77-79 and 219-220. |
| `N03-021` | Lines 269-270. |
| `S09-001` | Lines 205-206, 213-214, and 221-226. |
| `S10-001` | Lines 104-122. |
| `S10-002` | Lines 124-159. |
| `PLN-05-001` | Lines 22-27 and 70-75. |
| `PLN-05-002` | Lines 54-56 and 181-185. |
| `PLN-05-003` | Lines 77-79 and 219-220. |
| `PLN-05-004` | Lines 269-270. |
| `Q03-001` | Lines 22-25 and 70-75. |
| `Q03-002` | Lines 22-27 and 49-75. |

### Implementation consequences

The change alters observable callback traces, public observer prose, PRD
expectations, observer models, and stream-bridge delivery tests.
