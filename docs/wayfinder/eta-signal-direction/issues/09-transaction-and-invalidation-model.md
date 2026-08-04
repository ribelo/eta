# Transaction and invalidation model

Type: grilling
Status: resolved
Blocked by: 01, 02, 03, 06

## Question

What transaction and invalidation model gives Eta Signal atomic phase entry, one
closed invalidation frontier, and an explicit non-failing commit boundary?

Decide the phase model, transaction identity, planning result, staged-operation
partition, provisional-scope cleanup, rollback authority, commit authority, and
post-commit failure behavior. Cover ordinary bind switches, keyed removals,
nested combinations, cycle failures, callback defects, and independent graphs
on separate domains.

The result must assign each invariant to one deep module. It must resolve N1,
N2, and N5 rather than add checks around the current order.

## Answer

Eta Signal needs one private atomic-pass module. Its interface has one
operation:

```ocaml
val stabilize :
  graph ->
  runtime_contract ->
  (unit, stabilize_error) Eta.Effect.t
```

`stabilize` owns phase and exception-region orchestration. It delegates total
publication to `Eta_signal_commit_plan`. It delegates hook lifecycle and
failure aggregation to `Eta_signal_cleanup`.

The interface is private and concrete. Dynamic-operation helpers can contribute
declarative plans, but they cannot supply commit callbacks. Application and
library consumers do not receive phase, scope, transaction, or graph-mutation
capabilities.

The effect installs its finalizer before it starts planning. After commit, that
finalizer owns the `Delivering` session until the phase returns to `Idle`.
Interruption cannot occur between commit and finalizer ownership.

### Phase and identity

The phase state is one variant:

```ocaml
type phase =
  | Idle
  | Planning of planning_session
  | Delivering of delivery_session
```

There is no separately mutable transaction status or transaction option. There
is no observable committed phase between planning and delivery.

A transaction has one fresh physical identity:

```ocaml
type transaction_id = unit ref
```

`Eta_signal_transaction` creates this identity. Staged cells and phase-session
checks use the same identity. There is no second session or phase identity.

The implementation allocates the transaction and planning workspace before it
changes `Idle`. The planning and delivery session values carry the transaction
identity. Successful entry performs one phase-field assignment.

An allocation defect before that assignment leaves the graph idle. It does not
become `` `Counter_overflow "transaction id"`` because the design has no
transaction counter.

The design removes both module-global identifiers in `eta_signal_transaction`
and `eta_signal_stabilization`. Independent graphs therefore share no mutable
phase or transaction allocator across domains.

### Planning result and invalidation closure

Planning uses this internal result:

```ocaml
type planning_rejection =
  | Graph_error of graph_error
  | Defect of exn * Printexc.raw_backtrace

type planning_result =
  (sealed_commit_plan, planning_rejection) result
```

The atomic-pass module maps `Graph_error` to the Eta typed-error channel. It
maps `Defect` to an Eta defect and preserves the original backtrace.

The plan contains these prepared values:

- One immutable closed invalidation frontier.
- Explicit commit and discard partitions for bind operations.
- Explicit commit and discard partitions for keyed operations.
- The same partitions for each future private dynamic-operation kind.
- Precomputed replacements for staged cells, topology, scopes, demand, timers,
  observer state, and counters.
- A post-commit batch of cleanup hooks, timer lifecycle work, and observer
  events.

Each dynamic operation declares exactly one owner node. The owner has these
meanings:

- A bind operation owns the bind node that changes its inner dependency.
- A keyed operation owns the keyed parent node, not a removed child.
- A future private operation owns the node whose committed state it changes.

A provisional operation uses its prospective node as the owner. The combined
planning graph contains committed and prospective node identities. An operation
without exactly one owner is an internal plan-construction defect.

Planning discovers dynamic operations and retirement roots to a fixed point.
Bind replacements contribute old scopes. Keyed removals contribute removed
child scopes. Future operations contribute their declared retirement roots.

Frontier closure traverses the combined planning graph. When closure reaches an
operation owner, that operation enters the discard partition. Its provisional
scopes become new roots. Closure and partitioning repeat until both are stable.

The planner then freezes the frontier and every partition. A keyed removal
commits when its keyed parent survives, although the removed child is inside the
frontier. Traversal or registration order cannot change these decisions.

Discard processing runs while rollback remains legal. It clears staged cells
and transfers attempt-owned provisional scopes to the cleanup ledger. It does
not mutate the committed topology.

The planner then validates the complete prospective topology. Scope errors,
counter errors, timer errors, and cycles reject the plan before publication.
No prospective edge enters committed adjacency during validation.

### Provisional cleanup

One cleanup ledger owns every attempt-created scope and cleanup hook. Each scope
has one lifecycle state:

```ocaml
type provisional_state =
  | Live
  | Discarded
  | Rolled_back
  | Committed
```

Discard changes `Live` to `Discarded`. Rollback changes each remaining `Live`
scope to `Rolled_back`. Commit changes each surviving `Live` scope to
`Committed`.

Each transition can add cleanup hooks once. The ledger rejects a second
transition and prevents rollback from repeating discarded-scope invalidation.

Planning rejection returns the rollback cleanup batch after the phase is
`Idle`. Successful commit transfers discard and retired-scope hooks into the
post-commit batch.

Cleanup claims each hook before invocation and invokes every hook once.
One hook failure does not skip later hooks. The ledger aggregates failures in
invocation order.

For planning rejection, the graph error or planning defect remains the primary
cause. Cleanup failures follow it as sequential causes. For post-commit work,
the first post-commit failure remains primary, and final cleanup failures follow
it.

### Commit and rollback authority

The sealed plan contains a private declarative mutation tape. The tape contains
engine-owned writes, not closures from bind, keyed, extension, instrumentation,
or user code.

Commit interprets only that prepared tape. It performs fixed field writes and
pointer replacements, publishes observer delivery state, clears planning
authority, and installs `Delivering`.

Commit performs no user callback, graph traversal, validation, dynamic
classification, result-producing operation, or allocation-dependent planning.
It cannot return a graph error.

Only the atomic-pass module can authorize rollback. Rollback is available only
while its current phase is `Planning` and its open transaction is live. No
rollback operation accepts a sealed plan or delivery session.

OCaml does not provide affine values or a static no-raise effect. Private phase
types, a sealed mutation vocabulary, and isolated control flow enforce the
available structural guarantee. Ticket 16 must add fault slots around the
boundary.

### Failure behavior

A typed planning error rolls back staged state, invalidates provisional state,
restores retryable pending work, and returns the graph to `Idle`.

A planning defect performs the same rollback. The result preserves the defect
and backtrace. The cleanup ledger preserves primary-failure precedence.

Successful commit enters `Delivering` inside the finalizer-owned effect. Timer
lifecycle work, disposal cleanup, observer callback construction, and observer
callback execution occur after this point.

A post-commit typed failure, defect, or interruption preserves the committed
snapshot and topology. The protected finalizer drains mandatory cleanup and
returns the phase to `Idle`. It never calls rollback.

Ticket 11 owns retry, coalescing, and callback-order details. This ticket fixes
only the transaction side of that contract.

### Scenario decisions

| Scenario | Required result |
|---|---|
| Ordinary bind switch | The bind node owns the operation. Its old scope retires, and a surviving bind commits all prepared writes. |
| Nested bind switches | Closure partitions every nested owner. A bind under a retired owner transfers its provisional branch to cleanup. |
| Keyed removal | The keyed parent owns the operation. The removed child scope retires while the surviving parent operation commits. |
| Keyed removal with nested bind | The keyed parent operation commits. Closure reaches the nested bind owner, so that bind discards. |
| Future dynamic combination | The private operation kind contributes retirement roots and declarative writes before frontier closure. |
| Cycle or scope failure | Planning rejects before committed topology changes. Rollback preserves the previous snapshot and retryable updates. |
| Selector or keyed-builder defect | The defect occurs during planning and causes rollback with provisional cleanup. |
| Observer callback defect | The finalizer drains cleanup and returns to idle. The committed snapshot remains current and rollback is unavailable. |
| Independent graphs on separate domains | Each graph owns its phase and uses fresh physical transaction identities without shared allocation state. |

The keyed-and-bind case directly closes N2. The nested bind cannot attach to a
valid top-scope signal after its keyed owner becomes invalid.

### Deep-module ownership

| Module | Sole invariant owner |
|---|---|
| `Eta_signal_atomic_pass` | Phase entry and transitions, rollback authorization, error-channel mapping, finalizer ownership, and the pre-commit/post-commit exception split. |
| `Eta_signal_transaction` | The single physical identity, pending-cell ownership, and all-or-none staged-cell publication or discard. |
| `Eta_signal_commit_plan` | Operation-owner meaning, dynamic discovery, frontier closure, partitions, prospective validation, the mutation tape, and total commit. |
| `Eta_signal_cleanup` | Provisional-scope lifecycle, exactly-once hook invocation, complete cleanup traversal, failure aggregation, and failure precedence. |

These are implementation modules, not new public seams. Ticket 15 can merge a
shallow wrapper, but it cannot split one listed invariant across callers.

### Rejected alternatives

The design rejects reordered writes around the current separate phase fields.
That correction preserves the invalid combined states that N1 exposed.

It rejects graph-local integer transaction identifiers. Physical tokens satisfy
identity without an overflow policy or shared allocator.

It rejects a callback-based extensible commit protocol. Such callbacks make
total commit a convention instead of a structural property.

It also rejects a complete immutable graph-snapshot rewrite in this ticket.
That design can provide pointer-swap publication, but it decides topology and
scheduling representation before tickets 10 and 15.

### Evidence

- Phase-entry reproduction and identity comparison:
  [ticket 02](02-atomic-phase-entry.md#answer).
- Keyed-and-bind reproduction and closure invariant:
  [ticket 03](03-keyed-bind-invalidation.md#answer).
- Incremental semantic requirements and non-contract choices:
  [ticket 06](06-incremental-engine-reference.md#answer).
- Current phase mutation and shared identifiers:
  `lib/signal/eta_signal_stabilization.ml:29-45,107-117` and
  `lib/signal/eta_signal_transaction.ml:41-70`.
- Current keyed mutation inside preflight:
  `lib/signal/kernel/eta_signal_kernel.ml:1670-1698`.
- Current transaction commit and staging-token clear:
  `lib/signal/eta_signal_graph.ml:203-227`.
- Current shared exception region:
  `lib/signal/eta_signal_stabilization_pass.ml:274-333`.

### Census rows resolved here

Confirmed current facts and defects: `EXE-013`, `EXE-014`, `N01-015`,
`N02-020`, `N05-002`, `N05-003`, `N05-004`, `N05-005`, `N05-006`,
`N05-007`, `N05-008`, `N05-009`, `N05-021`, `N05-022`, `N05-023`,
`N05-024`, `N05-025`, `N05-026`, and `N05-027`.

Accepted N1 and N2 design claims: `N01-016`, `N01-017`, `N01-020`, `N01-022`,
`N01-023`, `N02-025`, `N02-026`, `N02-027`, `N02-028`, `N02-029`,
`N02-030`, `N02-031`, `N02-032`, `N02-033`, `N02-035`, and `N02-036`.

Accepted N5 design claims: `N05-011`, `N05-012`, `N05-013`, `N05-014`,
`N05-015`, `N05-017`, and `N05-018`.

Accepted domain and route claims: `S16-001`, `S16-002`, `PLN-01-001`,
`PLN-02-001`, `PLN-02-002`, `PLN-03-001`, `PLN-03-002`, `REC-009`,
`REC-010`, and `REC-011`.

Amended claims: `N01-019`, `N02-034`, `N05-016`, and `S12-001`. Phase entry
preserves idle state, discard precedes sealing, and rollback stays private to
the active planning session.

Rejected alternatives: `N01-018`, `N01-021`, and `PLN-01-002`. A physical
identity has no transaction-counter overflow.

Retained impact and route facts: `N01-026`, `N02-039`, `N05-019`,
`PLN-01-004`, `PLN-02-004`, and `PLN-03-004`.

### Resolution spans

| Answer span | Census rows |
|---|---|
| Lines 46-79 and 243-256 | `N01-015`, `N01-016`, `N01-017`, `N01-018`, `N01-019`, `N01-020`, `N01-021`, `N01-022`, `N01-023`, `S16-001`, `S16-002`, `PLN-01-001`, `PLN-01-002`, and `REC-011`. |
| Lines 81-193 and 214-241 | `N02-020`, `N02-025`, `N02-026`, `N02-027`, `N02-028`, `N02-029`, `N02-030`, `N02-031`, `N02-032`, `N02-033`, `N02-034`, `N02-035`, `N02-036`, `PLN-02-001`, `PLN-02-002`, `REC-009`, and `REC-010`. |
| Lines 23-44 and 172-212 | `EXE-014`, `N05-011`, `N05-012`, `N05-013`, `N05-014`, `N05-015`, `N05-016`, `N05-017`, `N05-018`, `PLN-03-001`, and `PLN-03-002`. |
| Lines 195-229 | `S12-001`. |
| Lines 266-274 | `EXE-013`, `N05-002`, `N05-003`, `N05-004`, `N05-005`, `N05-006`, `N05-007`, `N05-008`, `N05-009`, `N05-021`, `N05-022`, `N05-023`, `N05-024`, `N05-025`, `N05-026`, and `N05-027`. |
| Lines 317-325 | `N01-026`, `N02-039`, `N05-019`, `PLN-01-004`, `PLN-02-004`, and `PLN-03-004`. |

### Implementation consequences

N1 changes transaction identity, phase state, atomic-pass orchestration, and
phase tests. The overflow harness loses its transaction-counter branch.

N2 changes bind planning, keyed planning, scope invalidation, commit planning,
and diagnostics. It also changes the Signal Map model and its transaction
tests.

N5 changes atomic-pass orchestration and its fault-injection tests. Ticket 16
must place fault slots on both sides of total commit.
