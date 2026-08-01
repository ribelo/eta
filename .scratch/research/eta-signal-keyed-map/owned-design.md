# Eta-owned DiffableMap: feasibility and minimum design

Date: 2026-08-01
Repository revision: `dbc470105790bc50d7ed34c72f965431c4657d8a`
Branch: `docs/eta-crux-requirements`
Head: `dbc470105790bc50d7ed34c72f965431c4657d8a`
Related ticket: [Keyed assoc and stable child identity](../../../docs/wayfinder/eta-crux-first-principles/issues/04-keyed-assoc-contract.md)
Product decision: [Diffable map product boundary](../../../docs/wayfinder/eta-signal-keyed-map/issues/03-diffable-map-product-boundary.md)

The product decision later selected a clean-room implementation and rewritten
Base test scenarios. Any copy recommendation below is a rejected research
alternative.

## Question

Can Eta own an immutable ordered map that applications use directly? Can
`eta_signal_map` reconcile related snapshots in change-proportional time?

If yes, what is the minimum representation, diff algorithm, and public
collection surface? If the guarantee needs tighter terms, state them.

## Settled inputs (not re-decided here)

1. Applications use the map type directly. Eta does not wrap a host map behind a
   conversion step at the public `assoc` / keyed-map boundary.
2. Change-proportional reconciliation is required for maps with shared
   persistent ancestry.
3. The structural laws in Keyed assoc and stable child identity remain.
4. Keyed assoc and stable child identity uses `Stdlib.Map.S` and accepts `O(n_old + n_new)`
   through `M.merge`. That collection choice is provisional again
   ([product decision](../../../docs/wayfinder/eta-signal-keyed-map/issues/03-diffable-map-product-boundary.md)).
5. Bonsai does not build keyed composition on plain Incremental. It depends on
   `Incr_map` over Core/Base map symmetric diff
   ([Incremental map tutorial](EVIDENCE.md#incremental-map-sources)).

## Method

Primary sources only:

| Source | Revision | Role |
|---|---|---|
| Base `Map` | `4e3b745fb95d66fa0e13601d7fa7aeaed7962043` | Tree representation and structure-sharing diff |
| Base map tests | same revision | Reconstruction and comparison counts |
| `Incr_map` | `21c6bc602c75d57242b4c3e945da597f82c6280f` | Keyed consumers of map diffs |
| Incremental tutorial | `6253411aa37e1ae758908bd285930659119eff2a` | Nested `mapi'` intent |
| OCaml `Map` | compiler source | Public surface comparison |
| Published papers | DOI values in the evidence manifest | Tree balance and set algebra |

No prototype was run in this research ticket. Claims that need measurement are
listed under **Must prototype before choosing**.

See the [evidence manifest](EVIDENCE.md) for immutable revisions and URLs.

---

## Verdict

**Feasible, with a tighter contract than the raw sentence "change-proportional
for shared ancestry."**

Eta can own an immutable ordered map whose public values are persistent
weight-balanced trees. Two values that are descendants of a common ancestor
through ordinary persistent updates share unchanged subtrees by physical
identity. Diff then skips shared subtrees and emits only
`Left` / `Right` / `Unequal` entries for the changed frontier.

That is exactly what Jane Street Base `Map.symmetric_diff` /
`fold_symmetric_diff` implement, and what `Incr_map` consumes. Eta does **not**
need Core or Base as a dependency if it reimplements this small tree + diff
kernel. It **does** need its own map type: `Stdlib.Map.S` exposes no symmetric
diff and no length/weight field that makes the fast path natural.

### Required tighter terms

State the guarantee as:

> The maps `old` and `new` use the same comparator witness and share persistent
> structure from a common edit ancestry. `fold_symmetric_diff old new
> ~data_equal` follows the **diff frontier** and the rebalanced spine. It does
> not follow the total cardinality.

Explicit non-guarantees:

1. **Independently built equal maps.** Two maps with the same key/data bindings
   built from different sequences (or rebuilt from lists) share no structure.
   Diff is `Θ(n)` key walks in the worst case. Correctness still holds.
2. **Loss of ancestry.** Serializing and reloading, converting through
   `bindings`/`of_list`, or reconstructing after a non-sharing transform severs
   the guarantee. Diff remains correct and falls back to linear work.
3. **Whole-root rebalance.** One edit can rotate the root. The Base fast path
   then falls back to enumeration on that region. Expected cost for a single
   persistent insert/remove on a large map stays `O(log n + k)` where `k` is the
   number of logical key changes (usually 1). Base's own comparison benchmark
   for successive single inserts into a 2²⁰-key map shows **median 24 key
   comparisons** per adjacent-pair diff (`test_map.ml`, size `1_048_576`).
4. **`data_equal` weaker than physical equality.** Base documents that
   `phys_equal x y` must imply `data_equal x y`. If the caller violates that
   (for example `fun _ _ -> false`), shared subtrees can be skipped and unequal
   common keys can be omitted from the change stream. This is a correctness
   precondition, not a performance footnote
   (`map_intf.ml` `symmetric_diff` doc).
5. **Comparator identity.** Diff requires the same total order. Base enforces
   this with a comparator witness in the map type. Eta must do the same or an
   equivalent module-level monomorphization. Mixing orders silently is
   forbidden. It must fail at compile time or raise immediately.

Under those terms the settled requirement is achievable. Without them, a
universal "change-proportional for any two maps that look related" claim is
**false**.

---

## What Bonsai / Incr_map actually rely on

### Symmetric diff element

Base (`map_intf.ml`):

```ocaml
type ('k, 'v) t = 'k * [ `Left of 'v | `Right of 'v | `Unequal of 'v * 'v ]
```

- `` `Left v `` — key present only in the left (old) map: removal.
- `` `Right v `` — key present only in the right (new) map: addition.
- `` `Unequal (v_old, v_new) `` — key in both, data not `data_equal`.

Keys in the stream are sorted.

### Tree representation (Base)

Weight-balanced BST (`Tree0` in `map.ml`):

```ocaml
type ('k, 'v, 'cmp) t =
  | Empty
  | Leaf of { key : 'k; data : 'v }
  | Node of {
      left : ('k, 'v, 'cmp) t;
      key : 'k;
      data : 'v;
      right : ('k, 'v, 'cmp) t;
      weight : int;  (* length + 1 *)
    }
```

Outer map:

```ocaml
type ('k, 'v, 'comparator) t = {
  comparator : ('k, 'comparator) Comparator.t;
  tree : ('k, 'v, 'comparator) Tree0.t;
}
```

Balance parameters `(delta, gamma) = (5/2, 3/2)` with citations to Nievergelt &
Reingold (1973) and Hirai & Yamamoto (2011) in the Base source comment.

Stdlib `Map` uses height-balanced AVL-style nodes with field `h:int` and **no**
public length. It already preserves physical identity on no-op data updates
(`if d == data then m`), but it does not expose a structure-sharing diff.

### Diff algorithm (Base)

Two layers:

1. **Fast structural recursion** (`Tree0.fold_symmetric_diff`):
   - if `phys_equal t t'` → return accumulator (shared subtree skipped).
   - if both `Empty` / one empty → fold all adds or removes.
   - if both leaves → key compare + optional unequal.
   - if both nodes with **equal root keys** → recurse left, delta root, recurse
     right.
   - otherwise → fall back to slow enumeration.

2. **Slow enumeration** (`Enum.fold_symmetric_diff` / `symmetric_diff`):
   - zipper-style inorder streams.
   - `drop_phys_equal_prefix` skips shared structure even in the slow path by
     comparing weights and physical identity while descending.
   - merge of two sorted enumerations yields Left/Right/Unequal.

Complexity characterization (from algorithm structure + Base tests, not a new
proof):

| Scenario | Diff work (key/data steps) |
|---|---|
| `phys_equal old new` | `O(1)` |
| Single insert/remove/update on shared ancestry | `O(log n)` spine + `O(1)` logical change (empirically ~24 comparisons at n=2²⁰) |
| `k` independent persistent edits from a common ancestor | Expected `O(k log n)` frontier, not `O(n)` |
| Independently built maps, size n and m | `Θ(n + m)` enumeration |
| Same keys, all data physically shared, structure diverged | The diff can still walk structure. `data_equal` short-circuits unequals |

Output construction for a changed map (insert path) remains classic persistent
BST cost: `O(log n)` new nodes, shared rest. That sharing **is** the ancestry
the diff needs.

### How Incr_map uses it

`Incr_map` keeps the previous input map and previous output (or node table) in
`with_old`, then on each stabilization:

```ocaml
Map.fold_symmetric_diff old_in new_in ~data_equal ~init:old_out ~f:(...)
```

Examples from `Incr_map` at the recorded revision:

- `unordered_fold` — apply add/remove/update to an accumulator.
- `generic_mapi` — set/remove output entries per change.
- `generic_mapi'` uses per-key expert nodes. An unequal change marks the data
  node stale. A left-only change invalidates and removes the node. A right-only
  change creates a scoped node and dependency.

Default `data_equal` is physical equality. That matches the Base precondition.

`observe_changes_exn` is the pure "stream of diffs between successive values"
observer: it folds `symmetric_diff` between `Changed (v1, v2)` pairs.

**Implication for Eta:** the engine does not need a journal of edits from the
application. It needs (old snapshot, new snapshot) plus a structure-sharing
diff. Applications only need to build maps with ordinary persistent updates.

---

## Design alternatives

### A. Tree structural sharing + symmetric diff (recommended minimum)

**Representation:** Eta-owned weight-balanced (or AVL with length) persistent
map. Comparator witness. Public immutable values.

**Diff:** Base-style `fold_symmetric_diff` with phys-equal short circuit.

**Pros**

- Matches the proven Incr_map substrate.
- Applications use one map type for storage and incremental input.
- No edit journal for producers to maintain.
- Insert/remove/update stay `O(log n)`.
- Output maps from keyed nodes can be built with the same `set`/`remove` and
  inherit sharing for the next stage.

**Cons**

- Eta owns a collection implementation (balance, join, split).
- Guarantee is ancestry-sensitive (see tighter terms).
- Package boundary: new `eta_*` library, not stuffed into root `eta`.

**Complexity summary**

| Operation | Time | Notes |
|---|---|---|
| `empty` / `singleton` | `O(1)` | |
| `add` / `set` / `remove` | `O(log n)` | `O(log n)` new nodes |
| `find` / `mem` | `O(log n)` | |
| `cardinal` | `O(1)` | from weight |
| `fold` / `bindings` | `O(n)` | |
| `fold_symmetric_diff` with shared ancestry | `O(log n + k)` expected | `k` = emitted changes |
| `fold_symmetric_diff` independent maps | `O(n + m)` | still correct |
| Build output map by applying `k` changes to previous output | `O(k log n)` | preserves output ancestry |

### B. Edit journals (delta lists) beside an opaque map

Each update appends `{Add|Remove|Update}` to a journal. Diff reads the journal
between versions.

**Pros:** trivial change-proportional replay when the journal is complete.
**Cons:**

- Applications must not bypass the journal (breaks "use the map directly").
- Independent snapshots and journal truncation need version indices.
- Composition (`merge`, nested maps) rebuilds journals or falls back to full
  scan.
- Memory: journals grow until compacted. Compaction reintroduces full diff.

**Rejected as primary design.** A journal can be an *internal* optimization
later. It must not be the public contract.

### C. Explicit version ancestry graph (DAG of map versions)

Store parent pointers and LCA-based diff.

**Pros:** can recover a change set even after some structure is lost.
**Cons:** heavy runtime metadata, GC retention of ancestors, complex API,
still fails after serialization. Overkill relative to structural sharing, which
already encodes ancestry in the heap graph.

**Rejected for V1.**

### D. Cached hashes / fingerprints per subtree

Store a content hash at each node. Diff skips equal hashes.

**Pros:** can skip equal subtrees even without physical sharing.
**Cons:**

- Hash maintenance on every update (`O(log n)` hash work, more constants).
- Hash collisions need a safe fallback walk.
- Does not remove the need for ordered merge when hashes differ.
- Physical sharing already gives free equality for the common case Incr_map
  cares about.

**Optional later augmentation**, not the minimum. Prefer phys-equal first.

### E. Hybrid (tree + optional local journal)

Persistent tree as source of truth. Optional short journal between stabilizations
for producers under Eta control.

**Pros:** can avoid even the `O(log n)` spine walk in hot engine-owned paths.
**Cons:** two sources of truth. Easy to desync. Violates "no fallback logic"
spirit if public API has dual paths.

**Defer.** Prototype this option only if the spine cost dominates keyed-node
work. `Incr_map` suggests that nested incremental work usually costs more.

### F. Depend on Base/Core Map

**Pros:** zero reimplementation. Battle-tested diff.
**Cons:** pulls Jane Street Base/Core into Eta's dependency cone. Package
boundary policy wants optional packages to own their deps. Eta core currently
avoids that stack. OxCaml/mainline packaging cost.

The product boundary rejects this option. Base remains a behavior oracle and
does not enter the runtime dependency graph.

### G. Keep `Stdlib.Map.S` and full `merge`

**Pros:** zero new collection in the prior linear contract.
**Cons:** cannot honor the reopened change-proportional requirement.
`Map.merge` / dual enumeration is `Θ(n_old + n_new)` always.

**Incompatible with the settled performance requirement.**

---

## Feasibility sketch

### Package and name

This research compared a separate map package with a map inside
`eta_signal_map`. [Diffable map product boundary](../../../docs/wayfinder/eta-signal-keyed-map/issues/03-diffable-map-product-boundary.md)
owns the selected package shape.

### Type shape

Two viable public shapes. Pick one in a follow-up decision ticket (prototype
both ergonomics):

**Shape 1 — first-class comparator witness (Base-like)**

```ocaml
type ('k, 'v, 'cmp) t
type ('k, 'cmp) comparator

val empty : ('k, 'cmp) comparator -> ('k, 'v, 'cmp) t
val set : ('k, 'v, 'cmp) t -> key:'k -> data:'v -> ('k, 'v, 'cmp) t
(* ... *)
val fold_symmetric_diff :
  ('k, 'v, 'cmp) t ->
  ('k, 'v, 'cmp) t ->
  data_equal:('v -> 'v -> bool) ->
  init:'acc ->
  f:('acc -> 'k * [ `Left of 'v | `Right of 'v | `Unequal of 'v * 'v ] -> 'acc) ->
  'acc
```

**Shape 2 — functor over ordered keys (stdlib-like monomorphization)**

```ocaml
module Make (Ord : Ordered_type) : sig
  type key = Ord.t
  type 'a t
  val empty : 'a t
  val set : key -> 'a -> 'a t -> 'a t
  val fold_symmetric_diff :
    data_equal:('a -> 'a -> bool) ->
    'a t -> 'a t ->
    init:'acc ->
    f:('acc -> key * [ `Left of 'a | `Right of 'a | `Unequal of 'a * 'a ] -> 'acc) ->
    'acc
  (* Map.S-like surface plus length and symmetric diff *)
end
```

**Recommendation:** Shape 2 for V1 if the main consumers are functors
(`Assoc (M)` / `Keyed_map (M)`). Shape 1 if polymorphic map-passing dominates
(Incr_map style). The tree+diff kernel is the same.

### Representation invariants

1. Persistent, immutable nodes.
2. Weight (or size) at every node. `cardinal` in `O(1)`.
3. Balance guarantees `O(log n)` path length.
4. Updates allocate a spine. Unchanged subtrees remain `phys_equal`.
5. No-op data update (`set` same key with `phys_equal` data) returns the same
   map value when possible (stdlib and Base both do this).
6. Comparator/order is fixed per map value / module.
7. Diff's `data_equal` must be a congruence extending physical equality. Public
   docs state this as a hard precondition. Default for keyed operators:
   `( == )`.

### Diff API (engine-facing, also public)

Minimum:

```ocaml
type ('k, 'v) change =
  [ `Left of 'v
  | `Right of 'v
  | `Unequal of 'v * 'v
  ]

val fold_symmetric_diff :
  data_equal:('v -> 'v -> bool) ->
  ('k, 'v, _) t ->
  ('k, 'v, _) t ->
  init:'acc ->
  f:('acc -> 'k * ('k, 'v) change -> 'acc) ->
  'acc
```

Optional:

- lazy `symmetric_diff` sequence (Base has it. Engine prefers fold).
- `iter_symmetric_diff` to avoid accumulator noise.

Do **not** accept a caller-supplied "diff callback without full scan" as the
only safety mechanism. Keyed assoc and stable child identity rejected that: omitted removals leave
stale scopes. The engine always derives the change set from two snapshots.

### Public collection operations for producers and `eta_signal_map`

**Ordinary application producers (minimum Map-like surface)**

| Op | Need |
|---|---|
| `empty` | yes |
| `singleton` | yes |
| `add` / `set` | yes (define replace vs duplicate policy) |
| `remove` | yes |
| `update` / `change` | yes |
| `mem` / `find` / `find_opt` | yes |
| `cardinal` / `is_empty` | yes |
| `fold` / `iter` | yes |
| `bindings` / `to_seq` / `of_seq` / `of_list` | yes (document ancestry loss on rebuild) |
| `map` / `mapi` / `filter` / `filter_map` | yes for ordinary transforms |
| `merge` / `union` | useful. Not required for first keyed node |
| `min_binding` / `max_binding` / `split` | optional V1 |
| Comparison `equal` / `compare` | yes. Implement with phys-equal prefix drop |

**`eta_signal_map` / private keyed node**

| Op | Need |
|---|---|
| Snapshot equality by physical identity on map values | staging cutoff |
| `fold_symmetric_diff` | reconciliation plan |
| `set` / `remove` on **output** map | apply child outputs incrementally |
| `empty` with same comparator as input | init |
| `cardinal` | empty/fast paths (Incr_map uses length) |
| `find` | read data when creating per-key nodes |
| Comparator access | build empty output / node tables |

The keyed node algorithm (engine, not map package):

1. On first value: fold all entries as adds. Run builders. Build output map.
2. On later value: `fold_symmetric_diff ~data_equal` against previous input.
3. For each `` `Right ``: provisional add (scope, builder).
4. For each `` `Left ``: plan removal (no builder).
5. For each `` `Unequal ``: stage data source only if `not (data_equal old new)`.
6. Commit/rollback follow the Keyed assoc and stable child identity protocol (preflight, remove
   before add, etc.). Diff only supplies the plan.

Output map construction: start from previous output map. `remove` left keys.
`set` right/unequal outputs. That preserves **output** ancestry for downstream
incremental consumers.

### What `eta_signal_map` publishes vs private

The product boundary ticket owns the package shape. The engine still needs a
private graph capability for the keyed node. It does not need a second map type.

The minimum engine consumer is the per-key data node described by
`Incr_map.mapi'` and Keyed assoc and stable child identity.

---

## Correctness analysis by scenario

### Insert (new key)

Persistent `set` creates `O(log n)` new spine nodes. Diff from parent emits one
`` `Right ``. Shared subtrees skipped. Keyed node runs one builder.

### Remove

Symmetric: one `` `Left ``. Keyed node plans disposal. Output `remove` shares
structure.

### Update same key

If data is `phys_equal`, the map can return the identical tree. Diff emits
nothing.

Custom equality can accept data that is not physically equal. A normal `set`
then rewrites the spine. The fast path compares the key node. `data_equal`
suppresses the logical change.

If `data_equal` is weaker than phys-equal, it violates the Base precondition. A
phys-equal shared subtree containing conceptually "unequal" data can be
skipped: **silent missed update**. Eta must document and test this
precondition. Keyed defaults use `( == )` or a true congruence.

### Independently built maps

Diff is a full sorted merge: `O(n + m)`. Semantics match `merge`. Keyed node
still correct. Builders run for all adds relative to previous snapshot. No
ancestry → no performance claim.

### Loss of ancestry

Examples: `of_list (bindings t)`, round-trip through JSON, `map` that rebuilds
every node even when function is identity (unless implemented to preserve
phys-equal data and structure carefully). After loss, next reconciliation is
linear. **Do not** promise change-proportional recovery.

Mitigations (documentation, not magic):

- Prefer in-place persistent edits over rebuilds.
- Provide `mapi` that preserves structure when `f` returns `phys_equal` data
  (Base/stdlib pattern).
- Teach producers that "same contents" ≠ "cheap diff".

### Data equality

- Engine data cutoff: caller `data_equal`, default `( == )`.
- Map key equality: comparator only. Never polymorphic `=`.
- Map value equality for diff: explicit `data_equal` argument every time.

### Comparator identity

- Functor shape: types prevent mixing different `Make(Ord)` maps.
- Witness shape: `'cmp` phantom + stored comparator. Binary ops require equal
  witnesses.
- Never take two maps ordered by different functions and "just merge".

### Output-map construction

Applying `k` changes with persistent `set`/`remove` yields a new map that shares
with the previous output. Downstream `fold_symmetric_diff` on outputs then also
benefits. Rebuilding the output with `of_list` each time **destroys** that
chain and must be forbidden in engine code.

---

## Relationship to Keyed assoc and stable child identity

| Prior item | With DiffableMap |
|---|---|
| `Assoc (M : Map.S)` | `M` becomes Eta map module (or signature including `fold_symmetric_diff` + length) |
| `M.merge` full plan | Replace plan construction with `fold_symmetric_diff` |
| `O(n_old + n_new)` | Upgrade claim under ancestry terms above |
| Identity / lifecycle / tokens | Unchanged |
| Reject generic caller diff callback | Still rejected. Engine owns diff via map ops |
| Reject framework-owned collection as conversion layer | Satisfied: applications store `Eta_signal_map.Map` values directly |

If Eta Crux keeps a functor, the signature is no longer plain `Stdlib.Map.S`.
It is an Eta map signature with symmetric diff. That is a deliberate break with
"any Map.S".

---

## What must be prototyped before choosing

Do not pick balance scheme, package name details, or witness vs functor on
prose alone. Prototype:

1. **Kernel correctness**
   - Quickcheck: for random maps and random edit scripts,
     `apply_diff (symmetric_diff a b) a = b` and reverse.
   - Precondition tests: `data_equal` weaker than phys-equal shows missed
     unequals under sharing (document, not "fix").
   - Comparator mismatch rejected.

2. **Ancestry performance gate**
   - Build map size `N ∈ {10³, 10⁵, 10⁶}`.
   - From a common ancestor, apply `k ∈ {1, 10, 100}` inserts/removes/updates.
   - Measure key comparisons and wall time of `fold_symmetric_diff`.
   - **Pass criterion:** for fixed `k`, cost grows like `O(log N)`, not `O(N)`.
   - Control: independently rebuilt equal maps must show `Θ(N)`.

3. **Loss-of-ancestry control**
   - `of_list (bindings t)` vs parent must be linear. No accidental sharing.

4. **Keyed-node integration sketch**
   - Minimal `mapi'`-shaped node over the prototype map inside `eta_signal`
     (or a scratch graph): stable per-key state across data updates. Removal.
     re-entry. Rollback.
   - Prove reconciliation visits only changed keys under ancestry (counter +
     instrumentation).

5. **Output sharing**
   - After `k` output updates, diff successive outputs is `O(k log n)`.

6. **Ergonomics**
   - Functor vs witness: write one small Taumel-shaped producer and one
     `Assoc` sketch each way. Compare type errors and conversion friction.

7. **Stdlib interop (optional)**
   - Cost of `of_stdlib` / `to_stdlib` if needed for migration. Document that
     conversion drops ancestry.

The prototype uses a clean-room weight-balanced tree from the cited papers. It
starts with parameters `(5/2, 3/2)` and uses Base only as a test oracle.
Fingerprints and journals are not part of the first prototype.

### Decision rule after prototype

- If ancestry gate fails for single-edit scripts → representation bug. Do not
  weaken the public guarantee.
- If ancestry gate passes but keyed-node cost is dominated by engine overhead →
  still ship tree+diff. Do not add journals.

---

## Papers and formal anchors

1. **Nievergelt & Reingold (1973).** *Binary search trees of bounded balance.*
   SIAM J. Comput. Weight-balanced trees. Cited in Base `map.ml`.
2. **Hirai & Yamamoto (2011).** *Balancing weight-balanced trees.* JFP 21(3).
   Valid `(delta, gamma)`. Base chooses `(5/2, 3/2)`.
3. **Adams (1992/1993).** Efficient sets via weight-balanced trees. Split/join
   algebra used widely in functional maps.
4. **Blelloch, Ferizovic & Sun (2016).** *Just Join for Parallel Ordered Sets.*
   Optimal `O(m log(n/m+1))` set algebra via join. Base cites PAM-related join
   ideas for multi-weight joins. Symmetric element-wise **diff for incremental
   UI** is simpler than full set algebra: it is ordered merge with phys-equal
   cuts, not necessarily join-based difference.
5. **Base implementation** is a behavior and performance reference for
   `fold_symmetric_diff`.
6. **Incr_map** is a consumer reference for `unordered_fold` and `generic_mapi'`.

There is no need for a separate academic "diffable map" paper: the data
structure is a persistent balanced BST. The diff is structure-sharing ordered
merge. Incremental's tutorial states the performance claim in engineering
terms.

---

## Minimum API sketch (illustrative)

```ocaml
(** Eta_signal_map.Map — persistent ordered maps with structure-sharing diff *)

module type Ordered_type = sig
  type t
  val compare : t -> t -> int
end

module type S = sig
  type key
  type 'a t

  val empty : 'a t
  val is_empty : 'a t -> bool
  val cardinal : 'a t -> int

  val mem : key -> 'a t -> bool
  val find_opt : key -> 'a t -> 'a option
  val add : key -> 'a -> 'a t -> 'a t      (* replace if present *)
  val remove : key -> 'a t -> 'a t
  val update : key -> ('a option -> 'a option) -> 'a t -> 'a t

  val fold : (key -> 'a -> 'acc -> 'acc) -> 'a t -> 'acc -> 'acc
  val map : ('a -> 'b) -> 'a t -> 'b t
  val mapi : (key -> 'a -> 'b) -> 'a t -> 'b t

  val bindings : 'a t -> (key * 'a) list
  val of_list : (key * 'a) list -> 'a t   (** severs ancestry relative to inputs *)

  val equal : ('a -> 'a -> bool) -> 'a t -> 'a t -> bool

  type 'a change =
    [ `Left of 'a
    | `Right of 'a
    | `Unequal of 'a * 'a
    ]

  (** Precondition: phys_equal x y implies data_equal x y.
      Complexity: change-proportional when [t0] and [t1] share persistent structure. *)
  val fold_symmetric_diff :
    data_equal:('a -> 'a -> bool) ->
    'a t ->
    'a t ->
    init:'acc ->
    f:('acc -> key -> 'a change -> 'acc) ->
    'acc
end

module Make (Ord : Ordered_type) : S with type key = Ord.t
```

Engine-only helper (same package or `eta_signal_map` private):

```ocaml
val apply_diff :
  data_equal:('a -> 'a -> bool) ->
  old:'a t ->
  new_:'a t ->
  init:'acc ->
  add:(key -> 'a -> 'acc -> 'acc) ->
  remove:(key -> 'a -> 'acc -> 'acc) ->
  update:(key -> old:'a -> new_:'a -> 'acc -> 'acc) ->
  'acc
```

---

## Explicit impossibility / non-claims

| Claim | Status |
|---|---|
| Change-proportional diff for **all** pairs of equal-sized maps | **Impossible** without content hashes or journals. Independently built trees force `Θ(n)` |
| Change-proportional diff after serialization round-trip | **Impossible** with pure structural sharing |
| Correct keyed lifecycle from an untrusted partial diff callback | **Rejected** in Keyed assoc and stable child identity. Engine must compute full change set |
| `Stdlib.Map.S` without extension carries the performance contract | **False** |
| Eta-owned persistent WBT/AVL+size + Base-style symmetric diff under ancestry | **Feasible** and sufficient for Incr_map-class operators |

---

## Source index

The [evidence manifest](EVIDENCE.md) gives immutable revisions, URLs, and paper
identifiers. This report uses these primary symbols:

- Base `Tree0.fold_symmetric_diff` and `Enum.drop_phys_equal_prefix`
- Base reconstruction and comparison-count map tests
- `Incr_map.generic_mapi'`
- Incremental `part3-map.mdx`
- the published weight-balanced-tree papers
