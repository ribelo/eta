# Candidate kernel seams

Date: 2026-08-06

## Scope

This report answers the
[Candidate kernel seams](../../../docs/wayfinder/eta-signal-execution-model/issues/05-candidate-kernel-seams.md)
ticket. It uses Design It Twice to compare four interface shapes.

This report selects prototypes. It does not select the final execution model.

## Constraints

Each candidate must preserve the
[binding Signal behavior](binding-signal-behavior.md). Private phases,
transactions, plans, queues, and topology records can change.

Each candidate must also pass the
[performance acceptance matrix](performance-acceptance-matrix.md). Static raw
propagation must allocate fewer than 100 words, independent of graph depth.

The raw operation includes source admission, affected-work scheduling,
propagation, cutoff, and atomic publication. Eta Effect, Eio, observer
callbacks, and timer daemons stay outside that operation.

The module must hide these invariants:

1. Dependencies evaluate before consumers.
2. Cutoffs receive the published value before the candidate value.
3. Suppression retains the published baseline.
4. A pre-publication failure preserves the committed snapshot.
5. A successful pass publishes one consistent snapshot.
6. Dynamic topology settles before publication.
7. Demand work follows zero-count transitions.
8. A retained key preserves its keyed child incarnation.
9. Observer candidates have one deterministic total order.
10. Work follows the affected frontier.

## Candidate A: declarative snapshot plan

This candidate uses a pure planner. The planner returns a sealed plan for a
separate commit adapter.

```ocaml
module Raw_plan : sig
  type snapshot
  type admissions
  type plan
  type error

  val plan : snapshot -> admissions -> (plan, error) result
end
```

The private plan contains these items:

- the base revision
- the prospective snapshot
- admitted source identities
- lifecycle intents
- ordered observer candidates
- the affected-work manifest

The plan contains identities and values. It does not contain commit closures.
The commit adapter checks the base revision and installs the prospective
snapshot with one root change.

### Depth and locality

The one-function interface has high depth. Propagation, topology, demand,
ordering, and semantic validation remain local to the planner.

Failure also stays simple. The planner discards a failed prospective snapshot,
so committed state needs no rollback.

### Main risk

A strict immutable snapshot must represent each changed cached value. A
depth-dependent changed chain therefore appears to require depth-dependent
storage.

Persistent path copies, existential value packages, and plan arrays can exceed
the static allocation gate. Reusable mutable journals remove this cost, but
they also remove strict snapshot purity.

### Verdict

Build one short falsification prototype. It needs source admission, unary maps,
cutoff, and snapshot installation at depths 1, 10, and 100.

Reject this candidate when one of these conditions occurs:

- static allocation reaches 100 words
- static allocation increases with depth
- commit invokes a graph closure
- the plan contains operation closures
- planning mutates committed graph state

Do not add Effect, Eio, observers, timers, bind, or keyed work before this
probe passes.

## Candidate B: direct propagation kernel

This candidate uses one synchronous mutable module. It propagates directly into
private attempt storage and returns a compact status.

The kernel is pure with respect to external effects. Graph callbacks are pure,
but the kernel can mutate its private in-process state.

```ocaml
module Raw : sig
  type t
  type 'a var
  type 'a signal
  type error

  type stabilization =
    | Quiescent
    | Committed
    | Committed_with_post_commit_work

  val set : t -> 'a var -> 'a -> unit
  val stabilize : t -> (stabilization, error) result
end
```

Graph construction remains behind typed constructors such as `watch`, `map`,
`bind`, and keyed `mapi`. The sketch shows the execution seam, not the complete
construction interface.

The implementation uses retained mutable storage:

- committed and candidate value slots
- intrusive dirty and touched links
- reusable affected-work queues
- attempt stamps
- compact rollback storage
- provisional scope arenas
- demand counters
- keyed child tables
- reusable observer candidate storage

A failed attempt restores touched committed metadata. It discards provisional
scopes and retains source admissions for retry.

### Effect seam

The raw interface contains no Eta type. A private driver interface exposes
opaque post-commit claims to two adapters:

1. the Eta Effect production adapter
2. a deterministic synchronous test adapter

The driver exposes one claim at a time. It does not expose nodes, scopes,
topology edits, generations, or journals.

The Eta adapter owns these operations:

- domain and runtime checks
- graph serialization and cancellation before a grant
- effectful variable-update ownership
- observer callback execution
- timer clock and daemon work
- typed Eta failure conversion

The kernel owns observer order, pending state, acknowledgment state, demand,
and timer intent identity. The adapter cannot reconstruct graph semantics.

### Depth and locality

This candidate has the best depth. One execution interface hides propagation,
rollback, topology, demand, keyed continuity, and observer selection.

The private driver is a real seam because production and deterministic test
adapters both use it. The driver keeps runtime effects separate without
widening the installed raw interface.

### Main risk

Rollback storage can recreate the current allocation slope. A boxed undo
closure for each changed node disqualifies this candidate.

The implementation must use reusable slots or compact reusable arrays.
Heterogeneous values and dynamic scope arenas still require measurement on
OxCaml.

### Verdict

Prototype this candidate. Issue 06 owns its static value-propagation subset.
Later issues add rollback, dynamic topology, Effect, observers, and timers in
that order.

## Candidate C: synchronous graph with explicit edge cursors

This candidate also owns mutable propagation. It moves effect execution to
package-private synchronous edge interfaces.

```ocaml
module Raw_edges : sig
  type t
  type delivery
  type lifecycle
  type timer_transition
  type error

  val stabilize : t -> (unit, error) result

  val next_delivery : t -> delivery option
  val acknowledge : t -> delivery -> (unit, error) result

  val next_lifecycle : t -> lifecycle option
  val next_timer_transition : t -> timer_transition option
end
```

The Eta adapter performs this observer protocol:

1. Get the next delivery while the graph is serialized.
2. Create and run the callback effect outside serialization.
3. Acknowledge success in a new serialized section.
4. Leave a failed or interrupted delivery pending.

The timer adapter consumes demand transitions. It owns the monotonic clock,
sleep, daemon lifetime, and stale-wake rejection.

### Depth and locality

The common propagation interface is small. The explicit cursors also make edge
work measurable without a complete declarative plan.

This interface is shallower than Candidate B. Adapter callers must understand
claim, execution, acknowledgment, retry, and lifecycle order.

The edge cursors are acceptable only as wrapped-private interfaces. Publishing
them will freeze observer and timer machinery as package contracts.

### Main risk

Existential delivery packages can allocate. That cost belongs to the observer
adapter row, but it must not affect observer-free propagation.

Repeated serialization crossings can also retain the current public-protocol
cost. Issue 09 must measure this seam before the finalist decision.

### Verdict

Prototype this seam after Candidate B supplies the raw kernel. Treat Candidate
C as an adapter experiment, not as a second propagation implementation.

The experiment determines whether explicit cursors are deeper than the private
driver claims in Candidate B. Keep only one seam after that comparison.

## Candidate D: injected execution ports

This candidate injects clock, serialization, delivery, and lifecycle ports into
the raw graph functor.

```ocaml
module Make
    (Clock : CLOCK)
    (Serialization : SERIALIZATION)
    (Delivery : DELIVERY)
    (Lifecycle : LIFECYCLE) : RAW
```

The design gives each dependency a production adapter and a test adapter.
However, these dependencies are not remote services.

Clock and timer scheduling are local-substitutable dependencies. They justify
private integration seams. Propagation, delivery ordering, acknowledgment, and
graph serialization are in-process protocols.

### Depth and locality

The actual interface includes four port interfaces, their error types, task
batches, ordering rules, cancellation rules, and acknowledgment rules.

The ports delegate Signal behavior instead of hiding it. A delivery error can
require changes in the kernel, serialization adapter, and delivery adapter.
This design has poor locality.

Task closures, batch arrays, and abstract timestamps can also consume the
static allocation budget before propagation starts.

### Verdict

Reject this candidate as a raw-kernel prototype. Keep clock and timer scheduling
as private integration seams in the later timer prototype.

Do not inject serialization or delivery policy into the raw propagation module.

## Comparison

| Candidate | Depth | Locality | Seam placement | Static allocation outlook | Decision |
|---|---|---|---|---|---|
| A: snapshot plan | High | High | Between planning and commit | Poor unless the probe disproves the storage risk | Short falsification probe |
| B: direct kernel | Highest | Highest | Between synchronous graph work and Eta effects | Best | Main prototype |
| C: edge cursors | Medium | Medium | Between committed edge state and effect execution | Good for raw work; adapter cost is uncertain | Adapter prototype |
| D: injected ports | Low | Low | Four seams inside the raw graph | Poor | Reject |

Candidate A gives the smallest type-level interface. Its immutable result,
however, exposes the cost of every prospective changed value.

Candidate B gives the best leverage. Callers learn one stabilization operation,
while the module owns all graph semantics.

Candidate C makes post-commit work explicit. This aids measurement but shifts
protocol knowledge into the adapter.

Candidate D creates seams for implementation choices that do not vary at the
raw graph interface. It makes the module shallow.

## Dependency strategy

| Dependency | Category | Placement |
|---|---|---|
| Propagation, topology, rollback, demand, and ordering | In-process | Hide in the raw module |
| Persistent Signal Map operations | In-process | Install with each keyed node |
| Eta Effect interpretation | In-process adapter | Outside the raw seam |
| Graph serialization and cancellation | Local-substitutable execution edge | Eta adapter, outside raw propagation |
| Monotonic clock and timer scheduler | Local-substitutable | Private timer seam |
| Observer callbacks and finish hooks | External effect edge | Fixed adapter protocol |
| Diagnostics | In-process read projection | Private committed-state view |

Signal has no remote-owned or true-external raw dependency. Network-style ports
do not improve this module.

## Prototype sequence

Use this sequence:

1. Build the static falsification probe for Candidate A.
2. Build the static direct-propagation kernel for Candidate B.
3. Reject every static implementation that fails issue 04.
4. Add rollback storage to the eligible Candidate B kernel.
5. Add bind, demand, and keyed work without changing the raw execution seam.
6. Compare the private claims in Candidate B with the edge cursors in Candidate C.
7. Add Eta Effect, lane, observer, and timer adapters as separate layers.

The Candidate A and Candidate B static probes use the same frozen depth,
cutoff, operation, allocation, and wall-time rows. This comparison isolates the
representation choice.

## Recommendation

Use Candidate B as the primary hypothesis. Its synchronous direct-propagation
module has the best depth, locality, and static allocation outlook.

Use Candidate A only to test whether strict immutable planning can meet the
static allocation gate. Stop that work at the first kill condition.

Use Candidate C to test the post-commit seam after the raw kernel passes.
Do not build a second graph engine for Candidate C.

Reject Candidate D. Keep necessary runtime variation at private integration
seams instead of the raw propagation interface.

This decision does not prove Candidate B correct or fast. Issues 06 through 10
must supply that evidence.
