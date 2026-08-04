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

Eta Crux supports one ordered persistent collection:

```ocaml
module Assoc
    (Order : Eta_signal_map.Map.Ordered_type) : sig
  val assoc :
    ?data_cutoff:'data Cutoff.t ->
    'data Eta_signal_map.Map.Make(Order).t t ->
    f:(key:Order.t -> data:'data t -> 'result t) ->
    'result Eta_signal_map.Map.Make(Order).t t
end
```

`Order.compare` defines key identity and deterministic output order. The input
and output use the direct persistent `Map.Make(Order).t` type.

The key is a plain `Order.t` value. It remains constant for one child
incarnation. A key change is a removal and an addition.

The data argument is one stable description for the child incarnation. A
same-key data update changes its value without replacing its identity.

`data_cutoff` defaults to physical equality. It receives the published data
before the candidate. A suppressed candidate keeps the published data.

The map cannot contain duplicate keys. The producer owns all other key
validation.

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

Each root creates one private `Eta_signal.Make` graph. It adapts that graph with
`Eta_signal_map.Make(Signal.Package)`.

The interpreter maps `Assoc(Order).assoc` to
`Signal_map.Keyed(Order).mapi`. It translates the graph-neutral Crux cutoff to
`Eta_signal.Cutoff.t`.

Signal Map owns stable-family entries, provisional child scopes, data sources,
dependency edges, affected-child indexing, rollback, and pure commit.

The committed Crux root frame contains the final keyed output and endpoint
manifest. Applications receive no Signal type, graph value, scope, or `Keyed`
module.

Eta Crux implements no `Keyed_map`, generic diff callback, `assoc_on`, or second
keyed engine.

### Complexity

Keyed reconciliation and child-only changes use the public Signal Map bounds.
Shared persistent ancestry gives change-proportional key comparisons. An
independent map remains correct with linear comparisons.

Builders run only for additions. Data publication runs only for accepted
same-key candidates. Disposal runs only for removals.

Live keyed state is linear in live keys. Persistent output patches preserve
unchanged ancestry for downstream diff.

### Rejected alternatives

`Stdlib.Map.S` is rejected because it exposes no persistent ancestry or
symmetric-diff contract. Conversion to the Eta persistent map severs ancestry
and retains an obsolete path.

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

The prototype has 101 behavioral checks for the old map path. Its identity,
rollback, removal, stale-token, re-entry, and lifecycle evidence remains useful.
The final Signal Map suite replaces its reconciliation evidence.
