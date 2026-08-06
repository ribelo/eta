# Generic typed value storage

Date: 2026-08-06

## Scope

This report answers the
[Generic typed value storage](../../../docs/wayfinder/eta-signal-execution-model/issues/16-generic-typed-value-storage.md)
ticket.

The report selects the private representation for node values and undo values.
It extends the direct kernel and sparse undo journal from issues 06 and 07.

The durable evidence is in
[`generic-value-storage-probe/`](generic-value-storage-probe/).
The probe is throwaway code and does not change the production Signal engine.

The probe covers static unary propagation and failed-pass rollback.
Dynamic topology, Effect, observers, timers, and the frozen finalist remain
outside this prototype.

## Answer

Use an existential typed node with embedded value and undo fields.

```ocaml
type packed_node = Node : 'a node -> packed_node

and 'a node = {
  mutable current : 'a;
  mutable undo : 'a;
  mutable written_in : int;
  compute : unit -> 'a;
  cutoff : 'a -> 'a -> bool;
}
```

The existential package stores heterogeneous nodes in one dense arena.
The hidden type connects `current`, `undo`, `compute`, and `cutoff`.

The compiler rejects a value of a different type.
The selected representation needs no `Obj.t` cast or per-node dispatch closure.

The sparse journal continues to store dense slot integers.
The first write in a pass copies `current` to `undo` and records the slot once.

A successful pass resets the active value-journal length in O(1).
A failed pass resolves the slot integers in reverse and restores each value.

The selected representation allocates 4 words for immediate integers at depths
1, 10, and 100.
It also allocates 4 words for preallocated boxed values at those depths.

Its largest paired wall-time ratio against matched Incremental is 0.983.
Every selected-candidate row passes the prototype threshold in all three pairs.

## Design It Twice

The comparison uses three private representations.
Each representation uses the same common scheduler and integer journal.

### A. Existential typed node

Candidate A embeds `current`, `undo`, and `written_in` in a typed node.
The arena keeps one existential package for each node.

Pattern matching on `Node node` opens the hidden type.
All value operations remain typed inside that match.

Candidate A adds no unsafe cast.
It also adds no operation closure beyond the node computation and cutoff.

### B. Erased flat node

Candidate B stores `current`, `undo`, and accepted source values as `Obj.t`.
Its private module converts typed values at construction, set, map, and read.

The public wrapper keeps a phantom type.
Module abstraction confines the casts to one implementation.

This representation has the same one-word runtime value fields as candidate A.
Therefore, erasure does not reduce value size or propagation allocation.

Its soundness depends on the private construction invariant.
The compiler cannot prove that an erased undo value has the node value type.

### C. Closure-packed typed cell

Candidate C stores values in a typed cell.
The arena retains packed evaluation, rollback, and stamp closures.

The values never cross an erased seam.
The closures hide each cell type from the scheduler.

This representation keeps type safety.
It adds retained closures and an indirect call during each evaluation.

### Comparison

| Property | A existential node | B erased node | C closure-packed cell |
|---|---|---|---|
| Same-typed undo | Compiler proof | Private cast invariant | Compiler proof |
| Unsafe value cast | No | Yes | No |
| Hot dispatch | Direct match and call | Direct call | Packed closure call |
| Value field size | One word | One word | One word |
| Static allocation | 4 words | 4 words | 4 words |
| Largest integer ratio | 0.938 | 0.967 | 1.158 |
| Largest boxed-old ratio | 0.983 | 1.042 | 1.154 |
| Verdict | Selected | Rejected | Rejected |

Candidate A has the deepest module.
It gives the compiler-enforced type relation without the closure cost of
candidate C.

Candidate B has no measured allocation advantage.
Its unsafe invariant therefore has no compensating benefit.

## Type and rollback evidence

The semantic suite creates one heterogeneous chain:

```text
int -> string -> record
```

Each candidate propagates the value through all three node types.
This result proves that one arena can retain heterogeneous nodes.

The failure suite writes the integer, string, and record nodes.
The next node raises before its first write.

Rollback restores every committed value.
The string and record values also recover their exact physical identities.

The retained admission then retries without another source write.
The retry publishes the latest accepted source value.

A first-write probe evaluates one node twice in the same pass.
The node enters the journal once and rollback restores the pre-pass value.

A cutoff probe fails after a candidate reaches a dependent node.
The next pass suppresses a different candidate.

The cutoff receives the committed value in both calls.
The failed candidate never becomes the cutoff baseline.

The active journal type is `int array`.
Its high-water prefix contains only immediate slot integers.

## Runtime representation

This decision covers ordinary OCaml values of the default `value` layout.
The current public `'a signal` interface uses that layout.

Standard OCaml integers are tagged immediate values.
They do not allocate a heap box.

Records, strings, arrays, closures, and ordinary floats use boxed heap values.
The node stores their pointers without copying their payloads.

An existing boxed value adds no propagation allocation.
A computation that creates a boxed result still pays for that result.

The fresh-record row allocates 6 words per operation.
Four words come from the inherited kernel path, and two words create the
record.

OxCaml unboxed layouts, such as `float#`, are not part of this interface.
Supporting those layouts requires a different kind-polymorphic public
interface.

## Write-barrier evidence

The garbage collector requires a write barrier when an old mutable block stores
a young pointer.
Generic value storage cannot remove that barrier safely.

The probe promotes one reference and uses two matched controls.
Both controls allocate one two-word record and call the same C black box.

The second control also stores the record in the promoted reference.
The time difference estimates one old-to-young store and remembered-set update.

| Pair | Construction ns | Construction and store ns | Estimated store ns |
|---:|---:|---:|---:|
| 1 | 1.091 | 2.015 | 0.924 |
| 2 | 1.093 | 2.018 | 0.925 |
| 3 | 1.091 | 2.015 | 0.924 |

Both controls allocate 2.000001 words per operation.
Thus the old-to-young store adds time but no ordinary OCaml heap allocation.

The fresh candidate rows exercise actual generic slots.
Each row allocates 6.000001 words.

| Candidate | Fresh depth-1 ns in each pair |
|---|---|
| A existential node | 29.382 / 29.595 / 28.139 |
| B erased node | 28.450 / 28.546 / 29.874 |
| C closure-packed cell | 30.867 / 30.943 / 31.243 |

These rows contain several source and node stores.
They prove the candidate behavior under write barriers but do not count barrier
calls.

The integer slot journal remains important.
A pointer journal adds another old-to-young store for each changed node.
Issue 07 measured that separate cost.

## Measurement protocol

The release build used the required OxCaml Nix shell.
Each workload ran in a fresh process on CPU 2.

Calibration started with one operation and doubled the operation count.
It stopped at 0.5 seconds or 16,777,216 operations.

Each process reported nine samples.
The run used three complete comparison pairs.

The three pairs used `ABC`, `BCA`, and `CAB` candidate order.
Thus each candidate occupied each process position once.

Each matched integer and boxed-old candidate process immediately followed its
own Incremental process.

The allocation formula was:

```text
minor words + major words - promoted words
```

Setup, graph construction, promotion, warm-up, the final read, and teardown
stayed outside the measured operation.

One operation set one source and stabilized once.
The boxed-old rows alternated two promoted records through identity maps.

The matched Incremental row used the same value class, graph depth, mutation,
stabilization, and final-read boundary.

The results are standalone prototype evidence.
Issue 11 owns the final run in the frozen comparison harness.

The complete samples are in
[`results.csv`](generic-value-storage-probe/results.csv).
The process medians are in
[`summary.csv`](generic-value-storage-probe/summary.csv).

## Immediate-integer measurements

The threshold is 1.20 against matched raw Incremental in at least two pairs.

| Candidate | Depth | Candidate ns in each pair | Ratios in each pair | Words |
|---|---:|---|---|---:|
| A | 1 | 27.881 / 28.088 / 28.088 | 0.868 / 0.832 / 0.845 | 4.000001 |
| A | 10 | 90.308 / 94.725 / 92.377 | 0.938 / 0.929 / 0.858 | 4.000001 |
| A | 100 | 843.885 / 858.127 / 844.469 | 0.861 / 0.621 / 0.850 | 4.000019 |
| B | 1 | 28.020 / 28.072 / 28.123 | 0.854 / 0.839 / 0.876 | 4.000001 |
| B | 10 | 98.849 / 94.109 / 97.591 | 0.967 / 0.887 / 0.962 | 4.000001 |
| B | 100 | 902.077 / 1150.799 / 903.890 | 0.873 / 0.862 / 0.879 | 4.000019 |
| C | 1 | 30.880 / 30.682 / 31.706 | 0.904 / 0.899 / 0.953 | 4.000001 |
| C | 10 | 110.414 / 116.711 / 113.204 | 1.137 / 1.158 / 1.071 | 4.000002 |
| C | 100 | 1012.439 / 1392.715 / 1078.325 | 0.933 / 1.042 / 1.042 | 4.000019 |

Every candidate passes every immediate-integer row.
Allocation stays fixed when graph depth increases.

The integer-specialized control is a broad lower bound.
It differs from the candidates in more than value representation.

## Boxed-old measurements

| Candidate | Depth | Candidate ns in each pair | Ratios in each pair | Words |
|---|---:|---|---|---:|
| A | 1 | 29.905 / 29.381 / 33.583 | 0.798 / 0.792 / 0.906 | 4.000001 |
| A | 10 | 97.913 / 100.131 / 101.069 | 0.973 / 0.983 / 0.945 | 4.000001 |
| A | 100 | 883.516 / 881.152 / 883.872 | 0.869 / 0.896 / 0.900 | 4.000010 |
| B | 1 | 30.335 / 30.249 / 30.138 | 0.806 / 0.804 / 0.803 | 4.000001 |
| B | 10 | 104.750 / 101.818 / 104.671 | 1.042 / 1.004 / 0.999 | 4.000001 |
| B | 100 | 905.853 / 911.043 / 988.739 | 0.854 / 0.922 / 0.984 | 4.000019 |
| C | 1 | 32.322 / 33.053 / 33.316 | 0.862 / 0.883 / 0.887 | 4.000001 |
| C | 10 | 115.631 / 116.294 / 117.541 | 1.099 / 1.154 / 1.104 | 4.000001 |
| C | 100 | 1055.048 / 1063.337 / 1056.467 | 0.960 / 1.079 / 1.075 | 4.000019 |

All three candidates pass every boxed-old row in all three pairs.

Candidate A has the smallest worst ratio.
It also has the strongest type guarantee and no packed operation dispatch.

## Limits

The prototype uses static unary chains.
It does not repeat the issue 06 fan-in and affected-work proofs.

The common scheduler is a reduced copy of the accepted kernel.
The prototype does not replace the integrated finalist.

The boxed-old rows propagate existing records through identity maps.
User computations that allocate at each depth add depth-dependent application
allocation.

The barrier controls estimate one store.
They do not count runtime barrier symbols or model all collector states.

The prototype does not cover unboxed OxCaml layouts, parallel domains, dynamic
topology, keyed work, Effect, Eio, observers, or timers.

## Decision

Use candidate A.
Store heterogeneous arena nodes as existential packages.

Embed `current`, `undo`, and `written_in` in the typed node.
Keep `compute` and `cutoff` under the same hidden type.

Keep the active sparse journal as a reusable integer array.
Record a dense slot once, before the first value write of a pass.

Commit the value journal by resetting its active length.
Rollback resolves slots in reverse and restores same-typed undo values.

Do not use `Obj.t` for value storage.
It adds an unsafe invariant without a measured size or allocation benefit.

Do not pack evaluation and rollback in retained per-node closures.
That representation adds indirection and has the largest measured ratios.

Use normal mutable-field assignments for generic values.
The required write barrier costs approximately 0.924 to 0.925 nanoseconds for
the measured old-to-young reference store.

Keep the public Signal seam unchanged:

```ocaml
val set : t -> 'a var -> 'a -> unit
val stabilize : t -> (stabilization, error) result
```

Issue 08 can now add dynamic topology around the existential arena.
Issue 11 must rerun the selected integrated kernel in the frozen harness.
