# Keyed assoc and stable child identity

Type: prototype
Status: resolved
Blocked by: 03

## Question

What exact public and engine contract gives `assoc` stable per-key computation
identity, state, and lifecycle without turning the core into a collection
framework?

The decision must cover:

- the input collection and comparator or key-module discipline.
- child construction for a newly present key.
- updates to data for an existing key without rebuilding its child.
- child output collection and deterministic key order.
- removal, scope disposal, stale injection, and later re-entry of the same key.
- duplicate or invalid key states that the chosen collection can represent.
- the narrow `eta_signal` capability needed to implement the contract.

Prototype the public type and the private engine seam. Show a keyed child with
local state across data updates, removal, and re-entry. Do not expose a broad
`Expert` or public scope API only to make `assoc` possible.

## Answer

### Public contract

Eta Crux supports one ordered keyed collection through a functor over a
caller-owned `Stdlib.Map.S` module:

```ocaml
module Assoc (M : Map.S) : sig
  val assoc :
    ?data_equal:('data -> 'data -> bool) ->
    'data M.t t ->
    f:(key:M.key -> data:'data t -> 'result t) ->
    'result M.t t
end
```

`M` defines key equivalence, key uniqueness, and deterministic output order.
The output uses the same map type as the input. `M.bindings` defines its linear
order.

The key is a plain `M.key` value. It remains constant for one child
incarnation. A key change is a removal and an addition.

The data argument is one stable description for the child incarnation. A
same-key data update changes its value without replacing its identity.

`data_equal` defaults to physical equality `( == )`. It controls per-key data
publication. It does not control the child-output cutoff.

`Map.S` cannot contain duplicate keys. Thus, `assoc` has no duplicate-key error
branch. The map producer owns all other key validation.

The callback is a pure description builder. It runs for a provisional addition
and can run again after rollback. The contract promises one committed child
incarnation for each continuously present key.

### Identity and ownership

A keyed child cell has this identity:

```text
(root, assoc-description-node, keyed-scope-incarnation,
 child-description-node)
```

The map module compares keys. Eta Crux does not use polymorphic equality or
hashes for keyed identity.

The same description node in two keyed scopes creates two cells. Reusing that
node twice in one keyed scope shares one cell. This rule follows the scope
dimension from ticket 03.

While a key remains present across committed snapshots, Eta Crux preserves:

- the keyed scope and its incarnation.
- the per-key data source.
- the child graph.
- local state-machine models.
- the injector incarnation.

An unequal data update stages the existing data source. It does not run the
builder, replace the child, or reset local state.

A committed removal disposes the keyed scope and its models. A later entry with
the same key creates a new scope, data source, injector incarnation, and default
models.

Each injector and queued action carries the keyed scope incarnation. Delivery
compares this token with the live child. Delivery never routes an old action by
key alone.

After removal, the old token remains stale after same-key re-entry. Ticket 05
defines the delivery-error type. Delivery must reject the stale token loudly.

A failed removal leaves the previous child live. Its injector remains valid
because the removal did not commit.

### Snapshot and lifecycle rules

`assoc` compares committed input snapshots. Intermediate map values before a
successful stabilization do not create lifecycle edges.

If code removes and re-adds a key before commit, the final map controls the
result:

- equal final data preserves the child without an update.
- unequal final data updates the existing child.
- committed absence disposes the child.

One committed map transition deactivates all removed children before it
activates any added child. Same-key updates have no `assoc` lifecycle edge.
Failed provisional additions never activate. Ticket 07 defines lifecycle
programs and work cancellation.

### Private engine seam

Eta Crux needs one dedicated keyed-map node in its private `eta_signal` engine
integration:

```ocaml
module Keyed_map (M : Map.S) : sig
  val create :
    ?data_equal:('data -> 'data -> bool) ->
    'data M.t signal ->
    f:(key:M.key -> data:'data signal -> 'output signal) ->
    'output M.t signal
end
```

This operator is not part of the Eta Crux application interface. Ticket 15
decides its package location and whether ordinary `eta_signal` users see it.

The node owns an entry map. Each entry contains the key, scope incarnation,
stable data variable, data signal, child signal, and keyed scope.

The node uses `M.merge` to make a complete plan:

- a left-only entry plans removal.
- a right-only entry plans addition.
- an equal common entry keeps its child unchanged.
- an unequal common entry plans a data-source update.

Eta Signal value staging is necessary but not sufficient. Scope validity,
dependency edges, and graph registries are mutable graph structure. Keyed edits
must join the graph preflight, commit, and rollback protocol used by dynamic
`bind`.

The pure phase creates provisional scopes and runs builders. It also stages data
cells, the entry map, dependency changes, and the output map. It does not
invalidate committed removals.

The structural preflight validates every scope and child. It also reserves all
counters and timer stops. No user callback runs after this point.

Commit first detaches and invalidates every removal. It then attaches additions
and publishes the staged cells. All operations after preflight are total.

Rollback invalidates provisional additions and discards staged values. It keeps
removal candidates attached and live. The previous snapshot remains observable
and the source update remains retryable.

Structural edits must not use a late `on_commit` callback after value
publication. An exception at that point cannot restore atomicity.

The private surface contains no public scope handle, `Expert` node API,
`assoc_on`, generic diff callback, or full `Incr_map` operator set.

### Complexity

`Stdlib.Map.S` does not expose a symmetric-diff operation. Eta Crux therefore
makes no change-proportional reconciliation claim for V1.

For a changed input map:

- reconciliation takes `O(n_old + n_new)` time through `M.merge`.
- transient reconciliation data takes `O(n_old + n_new)` space.
- live keyed engine state takes `O(n_live)` space.
- builders run for additions only.
- data publication runs for unequal common keys only.
- disposal runs for removals only.

The linear scan does not replace unchanged child graphs. Their state and
expensive computations remain incremental. Performance work can revisit the
input collection only after measurements show that reconciliation dominates.

### Rejected alternatives

A framework-owned keyed collection duplicates the host map type and creates
conversion work. Its required construction and interoperation surface also
pulls Eta Crux toward a collection framework.

A generic ordered-diff callback is not safe enough. The engine cannot detect an
omitted update or removal without doing its own full scan. Such an omission can
retain stale data or a live removed scope.

A whole-map `bind` replaces the complete branch after each map change. It
destroys per-key state and fails the main contract.

A changing key description gives a false capability. The key cannot change
inside one incarnation. Callers that need a constant description can use
`return key`.

List input, duplicate reporting, `assoc_on`, and a full incremental collection
library are not part of V1 `assoc`.

### Evidence and prototype

Bonsai `assoc` and `gather_assoc.ml` provide the per-key state and constant-key
reference. The reviewed Bonsai source is commit
`1e4682c1312e737aa94554139a28ebcd0c077bd6`.

`Incr_map.mapi'` provides the per-key data-node and invalidation reference. The
reviewed source is commit `21c6bc602c75d57242b4c3e945da597f82c6280f`.

The selected prototype is on branch `prototype/eta-crux-assoc-map` at commit
`dccefa64`:

- [keyed assoc prototype](https://github.com/ribelo/eta/tree/dccefa64/.scratch/prototypes/eta-crux-assoc/map-functor)

The prototype has 101 behavioral checks. It covers stable updates, rollback,
removal, stale tokens, fresh re-entry, lifecycle order, Taumel agent IDs, and
linear reconciliation. The checks pass in the OxCaml and upstream OCaml Nix
shells.
