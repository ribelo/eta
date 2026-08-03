# Typed observation plan for host delivery

Type: prototype
Status: resolved
Blocked by: 03, 04, 06, 07

## Question

Can an adapter attach a typed observation plan to opaque Eta Crux computations
and receive granular stabilized changes without changing the canonical typed
root result?

Prototype snapshot-only reconciliation and the smallest credible observation
plan. The observation plan must not expose `eta_signal`, public output paths,
type witnesses, `Obj`, or host callbacks during pure stabilization.

Exercise:

- one scalar projection.
- one change in a 10,000-row keyed collection.
- an unrelated projection that must not run.
- dynamic removal that disposes its observation exactly once.
- a stale injector that must not act after removal.
- deterministic delivery after the pure snapshot commits.

Compare API depth, allocations, recomputation, host mutation count, lifecycle
complexity, and testability. If the plan is not a small deep interface, keep
root snapshots and adapter-owned diffing until measured pressure justifies more.
Link all prototype assets from the answer.

## Answer

### V1 contract

Eta Crux V1 exposes no typed observation plan. One committed root output is the
only application observation boundary.

Each successful `Start` or application message returns the complete typed root
output. This rule also applies when that output compares equal to the previous
output.

The driver gives the output to its adapter after the atomic snapshot commit.
The adapter retains any previous output that its reconciliation needs.

The adapter owns output projection, equality, diff, rendering, and host
mutation. Eta Crux defines no change event, output path, observer cursor, or
host callback for these operations.

The driver delivers the output before it starts the mandatory post-commit
batch. Ticket 11 defines root failure after an adapter-delivery failure.

Pure stabilization never calls an adapter or mutates a host. The adapter sees
only the complete output of the committed graph structure.

### Incrementality

Incremental recomputation and host delivery use separate boundaries. Private
`eta_signal` nodes skip unrelated computation before Eta Crux constructs the
root output.

A suitable persistent output value preserves sharing across committed
snapshots. An adapter uses type-specific diff operations when its output type
provides them.

The prototype changed one row in a 10,000-row `eta_signal_map` collection. Its
persistent symmetric diff used 13 key comparisons.

`Stdlib.Map.merge` used 10,000 comparisons for the same change. Eta Crux makes
no generic change-proportional diff claim for arbitrary output types.

An adapter without a suitable persistent value or diff operation owns its
reconciliation cost. This cost does not widen the core observation boundary.

### Lifetime and transport

Root output delivery does not add an Eta Signal demand root. Observation
therefore does not keep an otherwise unnecessary computation alive.

Structural commit owns dynamic removal and disposal. An adapter sees a
host-visible removal through its output diff, but it does not own computation
disposal.

Endpoint incarnations remain independent from output reconciliation. Ticket 05
rejects a stale endpoint after removal and same-key re-entry.

A serialized driver transports the canonical root output. V1 has no second
codec, sequence, or failure surface for observation changes.

Tests inspect complete typed outputs and explicit adapter mutations. They do
not reproduce observer registration, disposal, or callback scheduling.

### Bonsai comparison

Bonsai uses the same split between internal incrementality and external root
reconciliation. Its driver observes one root result.

The Bonsai Web driver flushes actions, reads the result, and projects one root
`Vdom.Node.t`. It diffs this node against `prev_vdom` and applies the patch.

After the patch, the driver stores the new root node and triggers lifecycle
effects. It exposes no driver-level plan for observations inside the graph.

`Result_spec.view` projects a generic root result into the root VDOM value. It
does not attach an observer to a child computation.

`Bonsai.Edge.on_change` belongs inside the computation lifecycle. It does not
replace root-result delivery.

The reviewed Bonsai core is commit
[`1e4682c`](https://github.com/janestreet/bonsai/tree/1e4682c1312e737aa94554139a28ebcd0c077bd6).
The reviewed Bonsai Web driver is commit
[`989c18b`](https://github.com/janestreet/bonsai_web/blob/989c18b5381cad767365923d4f0b758c6f3c602c/web/driver.ml).

### Prototype result

The prototype compared root snapshots with the smallest credible typed plan.
Both candidates still produced the canonical root output from ticket 06.

For one changed row, both candidates performed one delivery, one row
projection, one host mutation, and 13 persistent diff comparisons.

The plan skipped one unrelated scalar adapter projection. It retained two
additional registrations and cursors, then allocated one changed-event wrapper.

The executable also covered committed removal, repeated stabilization, stale
and fresh endpoints, increasing-key delivery order, and host mutation after
commit. All scenarios passed.

### Rejected typed plan

The minimal plan adds scalar and keyed observations, plan composition, typed
lifecycle events, delivery batches, registrations, cursors, disposal, and
failure rules.

This plan does not replace the canonical output. It adds a second observation
algebra beside that output.

Eta Signal observers are demand roots. A direct implementation keeps an
observed subgraph necessary after the canonical output stops using it.

An external plan also lacks a safe name for an opaque dynamic child occurrence.
Exposing that name adds public scope identity or output paths.

Serialized execution adds another codec and failure surface for plan changes.
The measured scenario did not reduce host mutations.

These costs exceed the saved scalar projection. A later observation ticket
requires measured adapter pressure that persistent snapshot diff does not solve.

### Evidence

The selected prototype is on branch `prototype/eta-crux-observation-plan` at
commit `ca3945ce`:

- [prototype](https://github.com/ribelo/eta/tree/ca3945cecb4bf4c94648226c298936829355f5fd/.scratch/prototypes/eta-crux-observation-plan)
- [design](https://github.com/ribelo/eta/blob/ca3945cecb4bf4c94648226c298936829355f5fd/.scratch/prototypes/eta-crux-observation-plan/DESIGN.md)
- [results](https://github.com/ribelo/eta/blob/ca3945cecb4bf4c94648226c298936829355f5fd/.scratch/prototypes/eta-crux-observation-plan/RESULTS.md)

The prototype passes in the OxCaml 5.2.0+ox and upstream OCaml 5.4.1 Nix
shells.
