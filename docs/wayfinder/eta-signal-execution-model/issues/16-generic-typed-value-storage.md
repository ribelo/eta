# Generic typed value storage

Type: prototype
Status: resolved
Blocked by: 06, 07

## Question

Which representation for node values and undo slots preserves the four-word
static path for arbitrary typed values?

The accepted kernel and its rollback journal are integer-specialized. The public
interface carries `'a signal`, so the production kernel must store heterogeneous
values and their undo slots.

Compare the qualifying representations. Measure boxed values, unboxed integer
values, and the effect of the write barrier on a value slot. State whether the
static path stays at 4 words and stays independent of graph depth.

## Answer

Use existential typed nodes with embedded value, undo, and write-stamp fields.
The hidden node type connects the value, undo value, computation, and cutoff.

Keep heterogeneous nodes in one packed arena.
Keep the sparse rollback journal as immediate dense slot integers.

The selected representation allocates 4 words for immediate integers and
preallocated boxed values at depths 1, 10, and 100.
Its largest paired wall-time ratio against matched Incremental is 0.983.

A fresh boxed record increases the result to 6 words.
The extra 2 words create the record and do not come from storage.

The matched control estimates 0.924 to 0.925 nanoseconds for one old-to-young
value-slot store.
The write barrier adds no ordinary OCaml heap allocation.

Reject `Obj.t` erasure because it adds an unsafe invariant without a measured
size or allocation benefit.
Reject closure-packed cells because they add retained dispatch and have the
largest measured ratios.

The prototype, complete measurements, limits, and selected private shape are in
[Generic typed value storage](../../../../.scratch/research/eta-signal-execution-model/generic-typed-value-storage.md).
