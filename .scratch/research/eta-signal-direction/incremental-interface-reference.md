# Jane Street Incremental interface reference

## Evidence set

The primary `Incremental` checkout is
`/home/ribelo/projects/github/incremental`. Its `master` checkout is commit
`2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6`
(`v0.18~preview.130.100+614`) from
[janestreet/incremental](https://github.com/janestreet/incremental/commit/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6).
The public `.mli` is an include of the main interface
([`src/incremental.mli`, symbol `Incremental_intf.Incremental`, lines
1-1](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental.mli#L1)).
The behavior-bearing interface and implementation are
[`src/incremental_intf.ml`](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml)
and
[`src/state.ml`](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml).

The `incremental` checkout has no `Incr_map` source. The primary map checkout
is the sibling directory
`/home/ribelo/projects/github/incr_map`, at commit
`21c6bc602c75d57242b4c3e945da597f82c6280f`
(`v0.18~preview.130.106+341`) from
[janestreet/incr_map](https://github.com/janestreet/incr_map/commit/21c6bc602c75d57242b4c3e945da597f82c6280f).
This path difference is a source fact, not an inferred module split.

I read the complete `Incremental` and `Incr_map` interfaces. I traced the
implementation paths for node construction, recomputation, cutoffs,
observers, scopes, folds, clocks, memoization, snapshots, expert nodes,
incremental map operators, and lookup observers. I also read the Eta interfaces
at evidence-baseline commit
`4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc`.

## Finding: the coherent algebra is small

`Incremental` has one coherent graph algebra:

1. A generative graph instance owns one state and one state witness.
2. `const` and `Var.watch` provide values.
3. `map` and its n-ary forms provide pure fixed dependencies.
4. `bind`, `join`, and `if_` provide dynamic dependencies.
5. A cutoff decides whether a recomputed value propagates.
6. `observe` creates demand, and `stabilize` computes necessary stale nodes.
7. Array folds provide aggregate values.

The generative boundary is part of the type model. `Make` creates disjoint
incremental universes, and its state witness prevents values from different
universes from being mixed
([`Incremental.Make`, `Incremental.S`, lines
1970-2003](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1970-L2003)).
The small public algebra is in
[`Incremental.S_gen`, symbols `const`, `return`, `map`, `bind`, `join`, and
`if_`, lines 712-743](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L712-L743)
and
[`Incremental`, symbols `const` through `bind`, lines
1115-1170](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1115-L1170).

The rest of the interface surrounds this algebra. `return` is an alias for
`const`, the infix operators are aliases, and `both`, `all`, `sum_int`, and
`sum_float` are convenience forms. `map2` through `map15` are arity and
allocation conveniences. `Clock`, memoization, graph dumps, statistics,
`Expert`, and `Incr_map` are optional subsystems or performance tools. They
do not define the scalar signal algebra.

## Classification

### Constructors and combinators

| Class | Symbols and source | Finding |
| --- | --- | --- |
| Graph constructor | `Make`, `Make_with_config`, `State.create` ([interface lines 1047-1061](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1047-L1061), [implementation lines 1906-1940](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1906-L1940)) | Owns mutable scheduler state, counters, heaps, and observer roots. |
| Source constructor | `const`, `return`, `Var.create`, `Var.watch` ([interface lines 1126-1136](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1126-L1136), [implementation lines 1421-1446](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1421-L1446)) | `const` never changes. A variable stores the latest source value, and `watch` exposes one graph node for that variable. |
| Fixed combinator | `map`, `map2`-`map15`, `both` ([interface lines 1133-1145](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1133-L1145), [implementation lines 1445-1504](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1445-L1504)) | `map` callbacks are intended to create no nodes. The n-ary forms avoid intermediate pair nodes. |
| Dynamic combinator | `bind`, `bind2`-`bind4`, `join`, `if_` ([interface lines 1147-1194](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1147-L1194), [implementation lines 1535-1596](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1535-L1596)) | `bind` changes the graph when its left-hand value changes. `join` and `if_` are specialized dynamic selectors. |
| Collection convenience | `all`, `both`, `for_all`, `exists` ([interface lines 1222-1239](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1222-L1239)) | These are useful constructors, not additional algebraic primitives. `all` is an array fold, and `both` is a pair-producing map. |

The implementation creates one node for each fixed combinator. Dynamic
combinators create a change node and a result node. The change node forces
dynamic selection to happen before the selected result is recomputed
([`State.bind`, `State.join`, and `State.if_`, lines
1535-1596](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1535-L1596)).

Incremental distinguishes `Var.value` from `Var.latest_value` only during
stabilization. `latest_value` includes a value set during the active
stabilization
([`Var.value` and `Var.latest_value`, lines
1438-1446](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1438-L1446)).
Eta's `Var.value` reads the current source value, including recent sets. It
rejects reads during pure recomputation
([Eta `Var.value`, lines
292-298](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L292-L298)).
Thus, Eta covers the useful latest-source read outside pure recomputation
without a second public operation. The two interfaces are not equivalent during
stabilization. Eta's restriction preserves explicit dependencies.

A source contradiction is visible in the current interface. The `map` comment
says that the generalizations end at `map9`
([`map` comment, lines 1133-1136](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1133-L1136)),
but `Map_n_gen` and `S_gen` publish `map2` through `map15`
([`Map_n_gen`, lines 394-637](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L394-L637)).
The implementation also defines `map10` through `map15`
([`State.map10` through `State.map15`, lines 1478-1504](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1478-L1504)).
The exported signature, not the stale comment, is the current API evidence.

### Cutoffs

`Cutoff.t` is a first-class propagation predicate. It has specialized
physical, always, never, compare, equality, and function forms
([`Cutoff.create`, `Cutoff.should_cutoff`, and `Cutoff.equal`, lines
21-53](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/cutoff.ml#L21-L53)).
Every node starts with physical equality
([`Node.create`, lines 498-506](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/node.ml#L498-L506)).
`set_cutoff` changes the predicate after construction. When the predicate
returns true, the implementation retains the old value and does not enqueue
parents
([`State.maybe_change_value`, lines 984-1019](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L984-L1019)).

This is a semantic boundary, not a representation detail. A cutoff suppresses
propagation, but it does not suppress recomputation of the node itself. The
mutable `set_cutoff` surface is an expert-style control surface around the
core map and demand algebra
([`set_cutoff` and `get_cutoff`, lines 1594-1610](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1594-L1610)).

`Incr_map` adds two separate equality gates. `data_equal` controls which input
map changes reach an operator. `cutoff` in `mapi'` controls each dynamic
per-key data node
([`mapi'` and related signatures, lines 583-631](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map_intf.ml#L583-L631),
[`generic_mapi'`, lines 753-847](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L753-L847)).
That separation is useful evidence for keyed consumers. It is not a reason to
copy the complete `Incr_map` API.

### Observers and lifecycle events

An observer is a demand root. Stabilization computes necessary stale nodes,
not every node in the graph
([necessity and stabilization, lines 96-123](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L96-L123)).
The observer interface has:

- `Initialized`, `Changed`, and `Invalidated` for an observer value.
- `value` and `value_exn` for the last stable value.
- `on_update_exn` for post-stabilization delivery.
- `disallow_future_use` for explicit lifecycle end.

The node-level `on_update` surface adds `Necessary` and `Unnecessary`
([`Observer.Update`, `Incremental.Update`, lines 1449-1557](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1449-L1557)).
`Unnecessary` is a demand transition, not a terminal observer event. A node
can become necessary again.

Observer creation updates lifecycle state and active counts immediately.
Finalizers enqueue observers for later processing. At stabilization start, the
engine links new observers and unlinks disallowed observers. Those graph changes
apply the demand transitions
([`create_observer` and observer unlinking, lines 1130-1242](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1130-L1242)).
The default finalizer disallows an observer only when it has no update
handlers. A caller with handlers must call `disallow_future_use`
([observer lifetime, lines 223-232](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L223-L232),
[`disallow_future_use`, lines 1149-1177](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1149-L1177)).

Handlers run after recomputation and after the stabilization number advances.
The implementation first classifies each node as `Invalidated`,
`Unnecessary`, `Necessary`, or `Changed`, then runs the handlers
([`stabilize_end`, lines 1321-1363](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1321-L1363)).
An exception during stabilization poisons the incremental state. Later calls
to `stabilize` raise immediately
([stabilization failure rule, lines 131-132](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L131-L132),
[`stabilize`, lines 1371-1382](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1371-L1382)).

### Dynamic dependencies and scopes

`bind` evaluates its selector in a dynamic scope. Nodes created by the selector
belong to that scope. A left-hand change evaluates the new RHS and replaces the
selected edge. The default configuration then invalidates the old RHS nodes
([bind semantics, lines 141-211](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L141-L211),
[`Bind_lhs_change` recomputation, lines 687-729](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L687-L729)).
The invalidation walk records nodes created in the scope and nested scopes
([`invalidate_node` and `invalidate_nodes_created_on_rhs`, lines 394-467](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L394-L467)).

The Incremental configuration calls rescoping a compatibility hack. The default
configuration invalidates the replaced RHS
([configuration contract, lines
4-10](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/config_intf.ml#L4-L10),
[default configuration, lines
3-6](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/config.ml#L3-L6)).

`Scope.current` and `Scope.within` let a closure capture the graph scope in
which it creates nodes
([scope interface and documentation, lines 1361-1403](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1361-L1403),
[`Scope.within`, lines 617-634](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L617-L634)).
This scope is graph-topology state. It is not an effect resource scope.

`Expert.Dependency` and `Expert.Node` expose a lower-level dynamic edge
protocol. The callback can read changed dependencies, make a node stale,
invalidate it, and add or remove dependencies
([`Expert` interface, lines 1862-1967](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1862-L1967)).
The interface calls this surface experimental and warns about its
preconditions. It is a graph extension SPI, not the ordinary signal algebra.

### Folds and aggregation

`array_fold` recomputes the complete fold after all inputs stabilize.
`reduce_balanced` requires an associative reducer and uses changed-input
work. `unordered_array_fold` uses inverse or old/new update functions and
allows changed inputs to apply in any order
([array-fold interface, lines 1241-1305](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1241-L1305)).
The implementation has a full-recompute interval for the unordered form
([`State.array_fold` and `State.unordered_array_fold`, lines 1643-1682](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1643-L1682)).
`sum`, `opt_sum`, `sum_int`, and `sum_float` specialize this fold family
([sum implementations, lines 1721-1751](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1721-L1751)).

The algebraic requirement is associativity for balanced reduction. For an
unordered array fold, updates must give the same result in every permitted
application order. The specialized sum functions are convenience aliases.
These requirements matter more than the names of the functions.

`Incr_map.unordered_fold` applies the same idea to persistent map diffs. It
supports `data_equal`, per-key `update`, specialized initial computation,
finalization, and a transition-to-empty optimization
([`unordered_fold`, lines 633-673](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map_intf.ml#L633-L673),
[`unordered_fold_with_comparator`, lines 88-140](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L88-L140)).
Its `remove` operation must invert `add`. Operations for different keys must
give the same result in every order. This is an optional keyed aggregation
subsystem. It is not a replacement for the scalar fold algebra.

### Introspection and diagnostics

The core semantic queries are `is_const`, `is_valid`, and `is_necessary`
([interface lines 1115-1124](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1115-L1124)).
`node_value` deliberately exposes possibly stale or unnecessary values for
debugging, not for normal observation
([`Node_value` and `node_value`, lines 908-919](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L908-L919)).
`State.stats` walks necessary descendants and reports a diagnostic summary
([stats interface, lines 1088-1095](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1088-L1095),
[`State.stats`, lines 198-217](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L198-L217)).

`user_info`, `append_user_info_graphviz`, `pack`, `save_dot`, and
`For_analyzer` expose graph shape and labels
([debug and DOT interface, lines 1672-1712](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1672-L1712),
[`For_analyzer`, lines 2012-2015](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L2012-L2015)).
These are observability tools. They do not add computation laws.

### Memoization

`lazy_from_fun`, `memoize_fun`, `memoize_fun_by_key`, and weak variants
capture the scope at the point of memoizer creation. They run a cache miss
inside that saved scope
([memoization interface, lines 1612-1670](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1612-L1670),
[`memoize_fun_by_key`, lines 1605-1641](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1605-L1641)).
Weak memoizers enqueue unused tables for reclamation after stabilization
([`weak_memoize_fun_by_key`, lines 1942-1962](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1942-L1962)).

Memoization is a graph-construction correctness aid and a performance
subsystem. It is not a signal constructor. Its saved scope is important when
memoized functions create nodes.

### Snapshots and time

`freeze` is a graph latch. It keeps its input necessary until its predicate
accepts a value, then becomes a constant
([`freeze`, lines 1196-1204](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1196-L1204),
[`State.freeze`, lines 1753-1767](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1753-L1767)).
`Clock.snapshot` is a time-triggered latch. A past time returns an error. The
current time returns an immediate frozen value. A future time creates a
top-scope snapshot
([snapshot interface, lines 1844-1860](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1844-L1860),
[`State.snapshot`, lines 1812-1828](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1812-L1828)).

The clock is explicit. `advance_clock` moves a timing wheel and makes alarm
nodes stale. It does not call `stabilize`, and it rejects calls during pure
stabilization
([clock interface, lines 1759-1807](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1759-L1807),
[`State.advance_clock`, lines 1857-1891](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1857-L1891)).
`at`, `after`, `at_intervals`, and step functions are time-source
conveniences around this explicit clock.

### Expert operations

The expert interface has four semantic capabilities:

1. Read a child value from a dependency callback.
2. Make an expert node stale.
3. Invalidate an expert node.
4. Add or remove a stateful dependency edge.

`on_observability_change` reports transitions into and out of graph
observability. `do_one_step_of_stabilize` splits the scheduler loop but does
not change stabilization semantics
([expert interface, lines 1877-1967](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1877-L1967)).
The implementation enforces child/parent callback context in debug builds and
updates necessary edges only when the expert node is necessary
([`State.Expert`, lines 1964-2099](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1964-L2099)).

This surface is useful evidence about the invariants of a custom node. It is
not a small consumer interface. `Incr_map.mapi'` and `Incr_map.Lookup` use it
because they need per-key nodes and demand-aware dynamic edges
([`generic_mapi'`, lines 753-847](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L753-L847),
[`Lookup.create` and `Lookup.find`, lines 2081-2197](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L2081-L2197)).

## `Incr_map`: a separate keyed subsystem

`Incr_map` is a separate library over Core maps and Incremental
([`src/dune`, lines 1-6](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/dune#L1-L6),
[`Incr_map` overview, lines 537-546](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map_intf.ml#L537-L546)).
Its stated goal is to make output-map work proportional to input-map changes,
usually through `Map.symmetric_diff`.

The keyed surface has these classes:

- **Map transforms:** `of_set`, `map`, `mapi`, `filter_map`, `filter_mapi`,
  partition, merge, unzip, rekey, index, transpose, collapse, and expand.
- **Keyed folds and queries:** unordered folds, counts, extrema, bounds,
  `for_all`, `exists`, and group sums.
- **Dynamic per-key transforms:** `mapi'`, `filter_mapi'`, `map'`,
  `filter_map'`, `merge'`, `unzip_mapi'`, and `unzip3_mapi'`.
- **Convenience aliases:** `map` delegates to `mapi`, and `filter_map` delegates
  to `filter_mapi`. The query operations specialize key-aware forms
  ([generic map forms, lines 268-315](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L268-L315),
  [query aliases, lines 1898-1974](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L1898-L1974)).
- **Expert and observer extensions:** `Instrumentation`, `Lookup`, and
  `observe_changes_exn`. `Lookup` builds one diff updater and many lazy
  per-key expert nodes
  ([lookup interface, lines 1305-1351](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map_intf.ml#L1305-L1351)).
  `observe_changes_exn` is restricted to top-level scope and translates
  observer updates into map diffs
  ([`observe_changes_exn`, lines 1252-1283](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map_intf.ml#L1252-L1283),
  [implementation lines 1940-1963](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L1940-L1963)).

`merge_disjoint`, `rekey`, and `collapse_by` contain caller-held invariants.
For example, `merge_disjoint` documents incorrect output or a crash when the
inputs share a key
([`merge_disjoint`, lines 836-845](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map_intf.ml#L836-L845)).
These preconditions belong to this optional performance library. They are not
evidence that a consumer-facing signal API needs the same expert hazards.

The interface has one naming mismatch. The comment for `merge_both_some` calls
it `merge_both_same`
([comment and symbol, lines 824-834](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map_intf.ml#L824-L834)).
The symbol and implementation are `merge_both_some`
([implementation lines 625-685](https://github.com/janestreet/incr_map/blob/21c6bc602c75d57242b4c3e945da597f82c6280f/src/incr_map.ml#L625-L685)).

## Evidence for Eta Signal, without a parity goal

### External consumer leverage

The reference supports an evaluation of consumer leverage. It does not decide
the Eta interface:

- Sources, fixed maps, dynamic selection, cutoffs, demand, and stabilization
  form the smallest useful scalar system.
- Associative and changed-input folds can remove full aggregate recomputation
  from consumer code.
- Time, snapshots, and memoization need coherent lifecycle and effect contracts
  before they earn public Eta operations.
- Diagnostics help operators and maintainers, but they do not complete the
  scalar algebra.
- `Expert` helps extension authors. Its mutation hazards make it a poor ordinary
  consumer interface.
- Arity forms, infix operators, and specialized sums are conveniences. Their
  presence does not establish algebraic completeness.

This evaluation does not use current Eta repository adoption as an inclusion or
rejection rule.

### Effect boundary

Incremental exposes synchronous `Var.set`, `observe`, and `stabilize`.
User-function exceptions poison the state
([exception rule, lines 71-77 and 131-132](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L71-L132)).
Eta exposes source updates, observer creation, disposal, and stabilization as
`Eta.Effect` operations with typed graph and callback failures.

Sources:

- [Eta `graph_error` and effect boundary, lines 122-161](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L122-L161).
- [`Var.set`, `Observer.observe`, and `Observer.dispose`, lines 300-372](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L300-L372).

Eta therefore needs the Incremental algebraic evidence without adopting the
synchronous exception and poisoned-state contract.

### Consumer and source model

Incremental creates a variable and its watch node in a graph scope. `watch`
returns the same incremental for repeated calls
([`Var.create` and `Var.watch`, lines 1405-1436](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1405-L1436)).
Eta creates a source handle outside dynamic scope. `watch` is the graph
construction boundary, and source reads during pure recomputation raise an
ambiguous-scope error
([Eta `Var.create`, `Var.value`, and `Var.watch`, lines 262-304](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L262-L304)).
This is a consumer-model difference, not a missing Incremental feature.

Eta also rejects graph calls from another domain or runtime worker callback
and serializes effectful graph operations on a graph lane.

Source: [Eta graph ownership, lines 98-106](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L98-L106).

Incremental's state witness isolates graph instances but does not provide
this Eta runtime boundary.

### Cutoff and lifecycle model

Eta exposes `equal` at source, map, and observer construction. Its observer
advances its current stabilized value even when the callback cutoff suppresses
delivery.

Sources:

- [Eta equality and cutoff contract, lines 1-20 and 323-349](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L1-L20).
- [`Observer.observe`, lines 323-349](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L323-L349).

Incremental stores a mutable cutoff on every node and uses the cutoff to
retain the old node value and stop parent propagation. These are related
cutoff laws with different public placement.

Eta has explicit, idempotent observer disposal. Disposal skips pending
callbacks and refreshes demand-owned timer cleanup
([Eta `Observer.dispose`, lines 352-372](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L352-L372)).
Incremental has finalization plus `disallow_future_use`, and it exposes
node-level `Unnecessary` transitions. Eta's public value-update type has only
`Initialized` and `Changed`
([Eta update and observer types, lines 163-172 and 320-373](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L163-L172)).
The Incremental lifecycle type is evidence about node demand, not a direct
observer API for Eta.

### Dynamic dependency model

Eta's `bind` declares the same useful semantic intent as Incremental. It selects
one signal from another and invalidates nodes created in the replaced branch
([Eta `bind`, lines 524-541](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L524-L541)).
Eta also declares typed `Invalid_scope` reads and transactional rollback.
Incremental uses scope lists, invalid nodes, and a poisoned state after
failures. N1 and N2 show that Eta does not implement universal rollback at the
evidence baseline. The useful reference evidence is dynamic dependency
invalidation and demand. The failure and resource contracts differ.

### Stabilization and transaction model

Incremental publishes values and then runs update handlers. It has one
exception-poisoning boundary
([`stabilize_end`, lines 1321-1363](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/state.ml#L1321-L1363)).
Eta's public contract declares a snapshot boundary before callbacks, timer
cleanup, and disposal effects. It declares rollback for pre-commit graph
failures but not for post-commit failures
([Eta `stabilize`, lines 543-565](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L543-L565)).

The current implementation violates that contract at two boundaries. N1
mutates the phase before transaction allocation. N2 commits invalid bind
topology before the snapshot commit
([atomic phase entry](../../../docs/wayfinder/eta-signal-direction/issues/02-atomic-phase-entry.md#answer),
[keyed bind invalidation](../../../docs/wayfinder/eta-signal-direction/issues/03-keyed-bind-invalidation.md#answer)).
[Transaction and invalidation model](../../../docs/wayfinder/eta-signal-direction/issues/09-transaction-and-invalidation-model.md)
owns the final Eta boundary. Incremental supplies phase-separation evidence, not
a transaction contract for Eta.

### Time model

Incremental time is a synchronous timing-wheel subsystem. The caller advances
the clock explicitly, and time nodes become visible only after stabilization
([Incremental clock contract, lines 1759-1824](https://github.com/janestreet/incremental/blob/2e8ccbfeedecf167e2a6399bd751ee9eabf1f4f6/src/incremental_intf.ml#L1759-L1824)).
Eta time nodes are demand-owned runtime timer effects. Timer sources do not
call stabilization, and Eta samples a monotonic runtime clock with its own
coalescing and daemon rules
([Eta `Time`, lines 589-699](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L589-L699)).
The shared evidence is explicit demand and a defined observation boundary.
The clock owner, effect boundary, and catch-up rules differ.

### Fold and keyed package model

Eta's scalar signal package can use Incremental's fold distinctions:
full folds, associative balanced reductions, and changed-input updates.
Eta's keyed package is intentionally smaller. It publishes persistent maps. Its
`Keyed(Order).mapi` operator preserves per-key child identity and applies a
published-data cutoff
([Eta map diff contract, lines 67-109](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal_map/eta_signal_map.mli#L67-L109),
[`Keyed.mapi`, lines 118-185](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal_map/eta_signal_map.mli#L118-L185)).
`Incr_map` supplies a broad operator suite and relies on Core maps and
Incremental expert nodes. Eta's package and consumer model do not require
that suite.

The package split is explicit. `eta_signal` publishes the scalar signal
library. `eta_signal_map` publishes the keyed map surface.

Sources:

- [Eta signal Dune libraries, lines 1-28](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/dune#L1-L28).
- [`eta_signal.opam`, lines 1-18](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/eta_signal.opam#L1-L18).
- [`eta_signal_map.opam`, lines 1-17](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/eta_signal_map.opam#L1-L17).

`Incr_map` has the same broad architectural split from `Incremental`, but its
Core, comparator, and expert-node dependencies do not transfer to Eta.

### Introspection and expert surface

Eta exposes effectful `stats` and `to_dot` reads with typed graph errors
([Eta diagnostics, lines 567-587](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal/eta_signal.mli#L567-L587)).
The current public Eta interface has no public `Incremental.Expert`-shaped
module. Its keyed operator is a first-party package API, not a general custom
node SPI
([Eta public keyed API, lines 118-186](https://github.com/ribelo/eta/blob/4197be98d5e56a3bfd22a904ec4d84cb8fc69ddc/lib/signal_map/eta_signal_map.mli#L118-L186)).
The reference therefore supports a narrow consumer algebra plus separate
diagnostic and first-party keyed packages. It does not support public
Incremental parity as a goal.

## Checks, limits, and surprising facts

- `find`, `wc`, and `rg` confirmed the source files and symbol locations.
- The line-numbered interface and implementation reads covered the cited
  source ranges. The pinned GitHub links use the checkout commit identities
  above.
- No Eta production code or tests were changed. No build or test command was
  needed for this documentation-only research.
- `Incr_map` is absent from the requested `incremental` checkout but present
  in the sibling `incr_map` checkout. Treating the sibling as the primary
  source avoids guessing.
- The `map9` comment versus the exported `map15` surface is a real interface
  contradiction.
- The `merge_both_same` comment versus the exported `merge_both_some` symbol
  is a real `Incr_map` documentation mismatch.
- The source does not present `Incr_map` as part of the minimal Incremental
  algebra. It presents it as a separate package that consumes Incremental's
  cutoff, observer, scope, and expert protocols.
