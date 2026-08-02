# Public map API and key discipline

Type: prototype
Status: resolved
Blocked by: 05

## Question

What exact `Eta_signal_map.Map` API gives applications normal map operations
without publishing a collection framework?

Prototype the strongest key-discipline candidates:

- a `Map.Make`-style functor over an ordered key module
- a first-class comparator witness carried by each map

Use one Taumel-shaped producer and one downstream keyed-composition example.
Compare inferred types, error messages, module plumbing, and output-map
construction.

Decide the minimum V1 operations. Cover construction, lookup, persistent edit,
ordered traversal, cardinality, equality, and symmetric diff. State duplicate
key behavior for every bulk constructor.

Decide whether `fold_symmetric_diff` accepts `data_equal` or reports all
physically changed values. The API must not permit a false equality function to
hide a real update silently.

Specify which transforms preserve ancestry when their output data remains
physically equal. Document which constructors and conversions sever ancestry.

Keep the prototype on a throwaway branch. Link its sketches and commit from the
answer.

## Answer

### Decision

Publish a `Map.Make` functor. Do not publish first-class comparator witnesses or
a hybrid interface in V1.

```ocaml
module type Ordered_type = sig
  type t

  val compare : t -> t -> int
end

type 'a change =
  | Left of 'a
  | Right of 'a
  | Changed of 'a * 'a

module type S = sig
  type key
  type 'a t

  val empty : 'a t
  val singleton : key -> 'a -> 'a t
  val of_list :
    (key * 'a) list -> ('a t, [ `Duplicate_key of key ]) result

  val is_empty : 'a t -> bool
  val cardinal : 'a t -> int
  val mem : key -> 'a t -> bool
  val find_opt : key -> 'a t -> 'a option

  val set : key -> 'a -> 'a t -> 'a t
  val remove : key -> 'a t -> 'a t
  val update : key -> ('a option -> 'a option) -> 'a t -> 'a t

  val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
  val to_list : 'a t -> (key * 'a) list

  val map : ('a -> 'b) -> 'a t -> 'b t
  val filter_mapi : (key -> 'a -> 'b option) -> 'a t -> 'b t

  val equal : ('a -> 'a -> bool) -> 'a t -> 'a t -> bool

  val fold_symmetric_diff :
    'a t ->
    'a t ->
    init:'acc ->
    f:('acc -> key -> 'a change -> 'acc) ->
    'acc
end

module Make (Order : Ordered_type) : S with type key = Order.t
```

This is the complete V1 map surface. V1 does not include aliases, merge, union,
split, range lookup, sequences, comparison, or a lazy diff.

`Ordered_type.compare` must define a stable total order. A zero result defines
key identity. A stored key must not mutate in a way that changes its order.

`set` retains the stored key representative when the supplied key compares
equal. It replaces only the data. Removal ends that representative lifetime. A
later insertion uses the new supplied key.

Two `Map.Make` applications to the same stable ordered-module path produce
compatible map types. Applications to different ordered-module paths produce a
compile-time type error.

### Bulk construction

`of_list` rejects the first duplicate key in input order. The error contains the
exact key value from the duplicate occurrence that caused rejection. It returns
no partial map. V1 has no silent last-write constructor and no exception-based
bulk constructor.

Empty input returns `empty`. A successful nonempty call shares no tree nodes
with a map that supplied its bindings.

### Equality and diff

`equal` is extensional equality modulo key identity. Both maps must contain the
same keys, and the equality function must accept each aligned data pair. The
data-call order is unspecified. If all calls accept, `equal` calls the function
once for every aligned pair. It does not skip a physically identical root or
subtree. After the function rejects a pair, `equal` makes no more data calls.

`fold_symmetric_diff` accepts no data-equality function. It reports `Changed`
when aligned data values are not physically equal. A caller equality function
cannot hide a map update.

Physical identity is the complete data-change boundary. Mutating one data
object between snapshots does not produce `Changed`. Two distinct objects
produce `Changed`, even when their fields are equal.

`Left` contains data present only in the first map. `Right` contains data
present only in the second map. `Changed` contains first-map data and second-map
data.

Events use increasing key order. `Left` and `Changed` use the first-map key
representative. `Right` uses the second-map representative.

The keyed operator receives every physical `Changed` event. Its logical cutoff
must compare new data with the currently published child data. It must not
compare only two consecutive raw map snapshots.

### Ancestry

`set`, `remove`, and `update` retain unchanged subtrees. A physical no-op returns
the same map root.

`map` and `filter_mapi` retain a node when its key remains, its output data is
physically equal, and its children remain unchanged.

`empty` contains no tree ancestry. `singleton` starts one fresh node. Nonempty
`of_list`, list reconstruction, serialization, and other map conversions sever
ancestry.

Independently built maps remain semantically comparable. Their diff can require
linear work.

### Candidate comparison

The functor type is `'a Agent_map.t`. The witness type is
`(Agent_id.t, 'a, Agent_order.witness) Map.t` and stores a comparator value in
each map.

Both candidates reject cross-order diff at compile time. The functor error names
the two map modules. The witness error names phantom witness types.

The functor makes the same-order output rule automatic inside a keyed module.
The witness form needs an explicit shared-witness constraint. No current caller
needs generic key-polymorphic map functions.

### Evidence

The prototype is on branch `prototype/eta-signal-map-api` at commit `c8da065d`:

- [Public map API prototype](https://github.com/ribelo/eta/tree/c8da065d/.scratch/prototypes/eta-signal-map-api)

Run all checks after checkout:

```sh
bash .scratch/prototypes/eta-signal-map-api/run.sh all
```

The prototype passes under OxCaml `5.2.0+ox` and mainline OCaml `5.4.1`. It
checks inferred types, cross-order errors, stable representatives, duplicate
rejection, transform identity, and physical-only diff. Both independent reviews
pass.

### Deferred

The keyed-operator ticket owns the public operator type and logical cutoff. The
executable-law ticket owns named production tests for this interface. The
integration ticket owns Eta Crux and Taumel call-site changes.
